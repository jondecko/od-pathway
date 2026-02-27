shader_type spatial;
render_mode blend_mix, cull_disabled, depth_draw_never;

// Triplanar + edge-fade shader for pathway mesh strips.
//
// Projects a texture using world-space triplanar mapping (matching
// tb_texture.gdshader) so the pathway tiles align with brush geometry that func_godot creates.
// Edge alpha fades via UV.x (default) or depth-buffer comparison.

group_uniforms texture;
uniform sampler2D albedo_texture : source_color, filter_linear_mipmap, repeat_enable;
uniform float triplanar_scale : hint_range(0.1, 20.0, 0.1) = 2.0;
uniform float triplanar_sharpness : hint_range(1.0, 10.0, 0.5) = 5.0;

group_uniforms edge_fade;
uniform bool use_depth_fade = false;
uniform float edge_fade_width : hint_range(0.0, 0.5, 0.01) = 0.15;
uniform float end_fade_length : hint_range(0.0, 0.5, 0.01) = 0.1;
uniform float edge_fade_depth : hint_range(0.0, 2.0, 0.01) = 0.3;

group_uniforms shading;
uniform float roughness_value : hint_range(0.0, 1.0, 0.05) = 0.85;
uniform float pathway_alpha : hint_range(0.0, 1.0, 0.05) = 1.0;

uniform sampler2D depth_texture : hint_depth_texture;

varying vec3 world_pos;
varying vec3 world_normal;


void vertex() {
	world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	world_normal = normalize((MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz);
}


float compute_uv_fade(vec2 uv) {
	// Fade at lateral edges (UV.x near 0 or 1)
	float side_dist = min(uv.x, 1.0 - uv.x);
	float side_fade = smoothstep(0.0, edge_fade_width, side_dist);
	// Fade at path ends (UV.y near 0 or 1)
	float end_dist = min(uv.y, 1.0 - uv.y);
	float end_fade = smoothstep(0.0, end_fade_length, end_dist);
	return side_fade * end_fade;
}



void fragment() {
	// Triplanar blend weights (same as tb_texture.gdshader)
	vec3 blend = pow(abs(world_normal), vec3(triplanar_sharpness));
	blend /= max(blend.x + blend.y + blend.z, 1e-6);

	// Sample texture from each axis using world position
	float inv_scale = 1.0 / triplanar_scale;
	vec3 sample_x = texture(albedo_texture, world_pos.yz * inv_scale).rgb;
	vec3 sample_y = texture(albedo_texture, world_pos.xz * inv_scale).rgb;
	vec3 sample_z = texture(albedo_texture, world_pos.xy * inv_scale).rgb;

	vec3 color = sample_x * blend.x + sample_y * blend.y + sample_z * blend.z;

	// Edge fade
	float fade;
	if (use_depth_fade) {
		// Depth-buffer fade: compare fragment depth to scene depth
		vec2 screen_uv = SCREEN_UV;
		float scene_depth_raw = texture(depth_texture, screen_uv).r;

		// Reconstruct linear depths
		vec4 scene_ndc = vec4(screen_uv * 2.0 - 1.0, scene_depth_raw, 1.0);
		vec4 scene_view = INV_PROJECTION_MATRIX * scene_ndc;
		float scene_depth = -scene_view.z / scene_view.w;

		float frag_depth = FRAGCOORD.z;
		vec4 frag_ndc = vec4(screen_uv * 2.0 - 1.0, frag_depth, 1.0);
		vec4 frag_view = INV_PROJECTION_MATRIX * frag_ndc;
		float frag_linear = -frag_view.z / frag_view.w;

		float depth_diff = scene_depth - frag_linear;
		fade = smoothstep(0.0, edge_fade_depth, depth_diff);
	} else {
		// UV-based fade at lateral edges
		fade = compute_uv_fade(UV);
	}

	ALBEDO = color;
	ALPHA = fade * pathway_alpha;
	ROUGHNESS = roughness_value;
	METALLIC = 0.0;
	SPECULAR = 0.0;
}
