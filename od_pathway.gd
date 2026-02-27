## A brush-based pathway entity. Draw a brush shape on the floor in TrenchBroom
## and this script replaces it with a triplanar-projected pathway mesh that
## blends into the surrounding ground.
##
## The brush geometry is consumed at build time by [method _func_godot_build_complete].
## At runtime [method _ready] re-applies properties from [member func_godot_properties]
## because func_godot only fires [method _func_godot_apply_properties] in the editor.
##
## The generated [MeshInstance3D] uses [code]od_pathway_mesh.gdshader[/code] (loaded
## relative to this script) with triplanar projection.
##
## FGD definition: [code]od_pathway.tres[/code] (sibling file)
@tool
class_name PathwayEntity
extends Node3D

## Subdivisions per world unit for the grid mesh.
var step_length_divs: int = 4
## How far above the floor surface the mesh hovers.
var y_offset: float = 0.01
## Width of the alpha fade at polygon edges (UV space, 0-0.5).
var edge_fade_width: float = 0.3
## Overall opacity of the pathway (0.0 = invisible, 1.0 = full).
var pathway_alpha: float = 1.0
## Whether to raycast vertices down onto floor geometry.
var snap_to_floor: bool = true

@export var func_godot_properties: Dictionary


# ==== Godot Lifecycle ====

## Maps TrenchBroom entity key-value pairs onto this node's properties.
func _func_godot_apply_properties(props: Dictionary) -> void:
	func_godot_properties = props
	if "step_length_divs" in props:
		step_length_divs = int(props["step_length_divs"])
	if "y_offset" in props:
		y_offset = float(props["y_offset"])
	if "edge_fade_width" in props:
		edge_fade_width = float(props["edge_fade_width"])
	if "pathway_alpha" in props:
		pathway_alpha = float(props["pathway_alpha"])
	if "snap_to_floor" in props:
		snap_to_floor = bool(props["snap_to_floor"])


## Called after the map build. Extracts floor geometry from the brush mesh,
## replaces it with a grid-based pathway mesh using triplanar projection.
func _func_godot_build_complete() -> void:
	var source_mesh_instance: MeshInstance3D
	for child in get_children():
		if child is MeshInstance3D:
			source_mesh_instance = child
			break

	if not source_mesh_instance or not source_mesh_instance.mesh:
		return

	var brush_texture: Texture2D = _extract_brush_texture(source_mesh_instance)
	var mesh_data := _extract_mesh_data(source_mesh_instance.mesh)

	# Always remove the brush mesh
	source_mesh_instance.queue_free()

	if mesh_data.floor_tris.is_empty():
		push_warning("PathwayEntity: no floor triangles found in brush mesh")
		return

	_generate_pathway_mesh(mesh_data, brush_texture)


## Re-applies [member func_godot_properties] at runtime because
## [method _func_godot_apply_properties] only fires during the editor map build.
func _ready() -> void:
	if Engine.is_editor_hint():
		return
	if not func_godot_properties.is_empty():
		_func_godot_apply_properties(func_godot_properties)


# ==== Data Extraction ====

## Intermediate data extracted from the func_godot brush mesh, used by
## [method _generate_pathway_mesh] to build the pathway overlay.
class MeshData:
	## Floor triangles as 2D (XZ) — array of PackedVector2Array, 3 points each
	var floor_tris: Array[PackedVector2Array] = []
	## Per-triangle bounding rects for fast point-in-floor rejection
	var tri_bounds: Array[Rect2] = []
	## Y range of the brush: x=min, y=max
	var y_range: Vector2 = Vector2.ZERO
	## Bounding rect of all floor triangles
	var bounds: Rect2 = Rect2()


## Iterates all surfaces of [param mesh] and collects upward-facing triangles
## near the floor Y level, projected to XZ. Triangles whose average Y is more
## than 0.5 units above the minimum Y are skipped, as are faces whose normal
## has a Y component below 0.3 (walls and bottom faces).
func _extract_mesh_data(mesh: Mesh) -> MeshData:
	var data := MeshData.new()

	# First pass: find Y range
	var min_y := 1e10
	var max_y := -1e10
	for surface_idx in range(mesh.get_surface_count()):
		var arrays := mesh.surface_get_arrays(surface_idx)
		if arrays.is_empty():
			continue
		var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		for v in verts:
			if v.y < min_y:
				min_y = v.y
			if v.y > max_y:
				max_y = v.y
	data.y_range = Vector2(min_y, max_y)

	# Second pass: collect floor-level triangles projected to XZ
	var y_threshold := min_y + 0.5
	var all_floor_pts := PackedVector2Array()

	for surface_idx in range(mesh.get_surface_count()):
		var arrays := mesh.surface_get_arrays(surface_idx)
		if arrays.is_empty():
			continue
		var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]

		if indices.is_empty():
			indices = PackedInt32Array()
			for vi in range(verts.size()):
				indices.append(vi)

		var tri_count: int = indices.size() / 3
		for t in range(tri_count):
			var idx := t * 3
			var v0 := verts[indices[idx]]
			var v1 := verts[indices[idx + 1]]
			var v2 := verts[indices[idx + 2]]

			# Only floor-level faces
			var avg_y := (v0.y + v1.y + v2.y) / 3.0
			if avg_y > y_threshold:
				continue

			# Only upward-facing faces (skip walls and bottom faces)
			var normal := (v1 - v0).cross(v2 - v0).normalized()
			if normal.y < 0.3:
				continue

			var tri := PackedVector2Array()
			tri.append(Vector2(v0.x, v0.z))
			tri.append(Vector2(v1.x, v1.z))
			tri.append(Vector2(v2.x, v2.z))
			data.floor_tris.append(tri)
			data.tri_bounds.append(_tri_rect(tri))

			all_floor_pts.append(Vector2(v0.x, v0.z))
			all_floor_pts.append(Vector2(v1.x, v1.z))
			all_floor_pts.append(Vector2(v2.x, v2.z))

	if all_floor_pts.size() >= 3:
		var hull := Geometry2D.convex_hull(all_floor_pts)
		data.bounds = _polygon_bounds(hull)

	return data


## Reads the albedo texture from the first surface material of [param mesh_instance].
## Supports both [ShaderMaterial] and [StandardMaterial3D].
func _extract_brush_texture(mesh_instance: MeshInstance3D) -> Texture2D:
	var mesh := mesh_instance.mesh
	if not mesh or mesh.get_surface_count() == 0:
		return null
	var mat := mesh.surface_get_material(0)
	if mat is ShaderMaterial:
		var tex: Variant = mat.get_shader_parameter("albedo_texture")
		if tex is Texture2D:
			return tex
	elif mat is StandardMaterial3D:
		return mat.albedo_texture
	return null


# ==== Point-in-shape Tests ====

## Returns true if the point falls inside any floor triangle.
## Uses per-triangle AABB rejection to skip expensive polygon tests.
func _is_point_in_floor(pt: Vector2, data: MeshData) -> bool:
	for i in range(data.floor_tris.size()):
		if not data.tri_bounds[i].has_point(pt):
			continue
		if Geometry2D.is_point_in_polygon(pt, data.floor_tris[i]):
			return true
	return false


## Computes a signed distance field on the grid using a two-pass chamfer
## distance transform. O(n) where n = rows * cols, replacing the previous
## O(n * r^2) brute-force search.
func _compute_distance_field(
	inside_grid: Array[bool], rows: int, cols: int,
	grid_spacing: float, fade_world: float
) -> Array[float]:
	var count := rows * cols
	var INF_DIST := fade_world + grid_spacing * 2.0
	var dist_grid: Array[float] = []
	dist_grid.resize(count)

	# Initialize: 0 at boundary cells, INF elsewhere
	for i in range(count):
		dist_grid[i] = INF_DIST

	# Seed boundary cells (any cell adjacent to a different-status cell)
	for r in range(rows):
		for c in range(cols):
			var idx := r * cols + c
			var v := inside_grid[idx]
			if (c > 0 and inside_grid[idx - 1] != v) or \
				(c < cols - 1 and inside_grid[idx + 1] != v) or \
				(r > 0 and inside_grid[idx - cols] != v) or \
				(r < rows - 1 and inside_grid[idx + cols] != v):
				dist_grid[idx] = 0.0

	# Chamfer weights
	var d1 := grid_spacing         # orthogonal step
	var d2 := grid_spacing * 1.414 # diagonal step

	# Forward pass (top-left to bottom-right)
	for r in range(rows):
		for c in range(cols):
			var idx := r * cols + c
			var d := dist_grid[idx]
			if c > 0:
				d = minf(d, dist_grid[idx - 1] + d1)
			if r > 0:
				d = minf(d, dist_grid[idx - cols] + d1)
			if r > 0 and c > 0:
				d = minf(d, dist_grid[idx - cols - 1] + d2)
			if r > 0 and c < cols - 1:
				d = minf(d, dist_grid[idx - cols + 1] + d2)
			dist_grid[idx] = d

	# Backward pass (bottom-right to top-left)
	for r in range(rows - 1, -1, -1):
		for c in range(cols - 1, -1, -1):
			var idx := r * cols + c
			var d := dist_grid[idx]
			if c < cols - 1:
				d = minf(d, dist_grid[idx + 1] + d1)
			if r < rows - 1:
				d = minf(d, dist_grid[idx + cols] + d1)
			if r < rows - 1 and c < cols - 1:
				d = minf(d, dist_grid[idx + cols + 1] + d2)
			if r < rows - 1 and c > 0:
				d = minf(d, dist_grid[idx + cols - 1] + d2)
			dist_grid[idx] = d

	# Convert to signed UV values: inside = positive, outside = negative
	var uv_grid: Array[float] = []
	uv_grid.resize(count)
	for i in range(count):
		var uv: float
		if inside_grid[i]:
			uv = clampf(dist_grid[i] / fade_world * 0.5, 0.0, 0.5)
		else:
			uv = clampf(-dist_grid[i] / fade_world * 0.5, -0.5, 0.0)
		uv_grid[i] = uv
	return uv_grid


# ==== Mesh Generation ====

## Builds the pathway [MeshInstance3D] from pre-extracted [param data].
## Creates a grid mesh with signed distance field UVs for edge fading,
## optionally raycasts vertices onto floor collision, and assigns
## [code]od_pathway_mesh.gdshader[/code] as the material.
func _generate_pathway_mesh(data: MeshData, brush_texture: Texture2D = null) -> void:
	var base_y := data.y_range.x  # Bottom of brush — fallback position
	var ray_start_y := data.y_range.y  # Top of brush — raycast origin
	var bounds := data.bounds
	var grid_spacing := 1.0 / maxf(float(step_length_divs), 1.0)

	# World-space distance over which the edge fades to transparent
	var fade_world := maxf(edge_fade_width * 4.0, grid_spacing * 2.0)

	# Expand bounds so the mesh extends beyond the polygon for the fade
	bounds = bounds.grow(fade_world + grid_spacing)

	var cols: int = int(ceil(bounds.size.x / grid_spacing)) + 1
	var rows: int = int(ceil(bounds.size.y / grid_spacing)) + 1

	# Build inside/outside grid
	var inside_grid: Array[bool] = []
	inside_grid.resize(rows * cols)
	for r in range(rows):
		for c in range(cols):
			var pt := Vector2(
				bounds.position.x + c * grid_spacing,
				bounds.position.y + r * grid_spacing)
			inside_grid[r * cols + c] = _is_point_in_floor(pt, data)

	# O(n) chamfer distance transform → signed UV grid
	var uv_grid := _compute_distance_field(inside_grid, rows, cols, grid_spacing, fade_world)

	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)

	var space_state: PhysicsDirectSpaceState3D
	if snap_to_floor:
		var world := get_world_3d()
		if world:
			space_state = world.direct_space_state

	# Create grid vertices
	for r in range(rows):
		for c in range(cols):
			var gx := bounds.position.x + c * grid_spacing
			var gz := bounds.position.y + r * grid_spacing
			var vert := Vector3(gx, base_y, gz)

			if space_state:
				var ray_origin := Vector3(gx, ray_start_y, gz)
				var global_vert := to_global(ray_origin)
				var ray_from := global_vert + Vector3.UP * 1.0
				var ray_to := global_vert - Vector3.UP * 20.0
				var query := PhysicsRayQueryParameters3D.create(ray_from, ray_to)
				var result := space_state.intersect_ray(query)
				if result:
					var hit_normal: Vector3 = result.normal
					if hit_normal.dot(Vector3.UP) > 0.5:
						vert = to_local(result.position)

			vert += Vector3.UP * y_offset

			st.set_uv(Vector2(uv_grid[r * cols + c], 0.5))
			st.set_normal(Vector3.UP)
			st.add_vertex(vert)

	# Index quads that are inside OR near the edge (have any visible fade)
	for r in range(rows - 1):
		for c in range(cols - 1):
			# Include cell if any corner has uv_x > -0.49 (not deep outside)
			var any_visible := (
				uv_grid[r * cols + c] > -0.49 or
				uv_grid[r * cols + c + 1] > -0.49 or
				uv_grid[(r + 1) * cols + c] > -0.49 or
				uv_grid[(r + 1) * cols + c + 1] > -0.49)
			var any_inside := (
				inside_grid[r * cols + c] or
				inside_grid[r * cols + c + 1] or
				inside_grid[(r + 1) * cols + c] or
				inside_grid[(r + 1) * cols + c + 1])
			if not any_visible and not any_inside:
				continue

			var tl: int = r * cols + c
			var tr: int = tl + 1
			var bl: int = tl + cols
			var br: int = bl + 1

			st.add_index(tl)
			st.add_index(tr)
			st.add_index(bl)

			st.add_index(tr)
			st.add_index(br)
			st.add_index(bl)

	st.generate_tangents()

	var mesh_instance := MeshInstance3D.new()
	mesh_instance.name = &"PathwayMesh"
	mesh_instance.mesh = st.commit()
	mesh_instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF

	var mat := ShaderMaterial.new()
	var shader := load(get_script().resource_path.get_base_dir().path_join("od_pathway_mesh.gdshader")) as Shader
	if shader:
		mat.shader = shader
		if brush_texture:
			mat.set_shader_parameter("albedo_texture", brush_texture)
		mat.set_shader_parameter("triplanar_scale", 2.0)
		mat.set_shader_parameter("edge_fade_width", edge_fade_width)
		mat.set_shader_parameter("pathway_alpha", pathway_alpha)
		mat.set_shader_parameter("roughness_value", 0.85)
	mesh_instance.material_override = mat

	add_child(mesh_instance)
	if Engine.is_editor_hint():
		mesh_instance.owner = get_tree().edited_scene_root


## Returns the axis-aligned bounding [Rect2] of a three-point [param tri].
func _tri_rect(tri: PackedVector2Array) -> Rect2:
	var min_pt := tri[0]
	var max_pt := tri[0]
	for pt in tri:
		min_pt = Vector2(minf(min_pt.x, pt.x), minf(min_pt.y, pt.y))
		max_pt = Vector2(maxf(max_pt.x, pt.x), maxf(max_pt.y, pt.y))
	return Rect2(min_pt, max_pt - min_pt)


## Returns the axis-aligned bounding [Rect2] enclosing all points in [param polygon].
func _polygon_bounds(polygon: PackedVector2Array) -> Rect2:
	if polygon.is_empty():
		return Rect2()
	var min_pt := polygon[0]
	var max_pt := polygon[0]
	for pt in polygon:
		min_pt = Vector2(minf(min_pt.x, pt.x), minf(min_pt.y, pt.y))
		max_pt = Vector2(maxf(max_pt.x, pt.x), maxf(max_pt.y, pt.y))
	return Rect2(min_pt, max_pt - min_pt)
