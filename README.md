# od-pathway

A self-contained [func_godot](https://github.com/func-godot/func_godot_plugin) brush entity that converts TrenchBroom brush shapes into triplanar-textured pathway overlays with smooth edge fading.

Draw a brush on the floor in TrenchBroom, texture it with a tileable image (dirt, gravel, etc.), and it becomes a blended pathway that sits just above the surrounding geometry.

## How It Works

The brush you draw in TrenchBroom is just a shape template. Its upward-facing floor faces define the outline, then the original mesh gets deleted.

A 2D grid replaces it. Each grid point is classified as inside or outside the shape. A distance field then calculates how far each point is from the nearest edge. That distance gets baked into the mesh UVs, which is the key trick. Inside vertices get positive UV values (opaque), edge vertices get zero, and outside vertices get negative values (transparent).

The grid extends past the shape boundary so the fade has room to taper. The new mesh is offset slightly above the floor (0.01 units by default), so it's basically a really thin rug laying over top of the geometry that func_godot creates. A custom shader reads the UV values to control alpha at the edges and uses world-space triplanar projection so the texture tiles with the surrounding floor geometry.

## Files

| File | Purpose |
|------|---------|
| `od_pathway.gd` | Entity script. Extracts floor triangles from the brush, builds a grid mesh with distance-field UVs. |
| `od_pathway_mesh.gdshader` | Spatial shader. Triplanar texture projection + UV-based edge fade. |
| `od_pathway.tres` | FGD solid class definition. Registers the entity with func_godot/TrenchBroom. |
| `*.uid` | Godot UID files. Keep these alongside the scripts so references resolve at any path. |

## Setup

1. Copy the folder (including `.uid` files) anywhere in your Godot project. Godot will register the files on import regardless of where you place them.

2. Open your FGD main resource in the Godot inspector and add `od_pathway.tres` to the **entity_definitions** array.

3. Export your FGD and refresh it in TrenchBroom.

4. In TrenchBroom, create a brush entity using the `od_pathway` classname. Texture the brush with any tileable image.

5. Build the map in Godot. The brush will be replaced with a faded pathway mesh.

## Properties

These are configurable in TrenchBroom per-entity:

| Property | Default | Description |
|----------|---------|-------------|
| `step_length_divs` | `4` | Grid subdivisions per world unit. Higher = smoother but more vertices. |
| `y_offset` | `0.01` | How far above the floor the pathway mesh hovers. |
| `edge_fade_width` | `0.3` | Width of alpha fade at polygon edges (0-0.5). |
| `pathway_alpha` | `1.0` | Overall opacity (0.0 = invisible, 1.0 = full). |
| `snap_to_floor` | `true` | Raycast vertices down onto floor collision geometry. |

## Requirements

- Godot 4.x
- [func_godot](https://github.com/func-godot/func_godot_plugin) plugin installed

## Notes

- The `origin_type = 4` in the .tres means BOUNDS_CENTER (positions the entity at the center of the brush volume).
- The `collision_shape_type = 0` means NONE (pathways are visual-only, no collision).
- The `od_` prefix on the classname avoids naming conflicts. Feel free to rename it in `od_pathway.tres`.
- The `.uid` files let Godot resolve references by UID rather than path, so the folder works at any location in your project.
- The shader is loaded at runtime relative to the script location (`get_script().resource_path.get_base_dir()`).

## License

[MIT](LICENSE)
