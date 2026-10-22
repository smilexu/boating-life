shader_type spatial;
render_mode cull_disabled, diffuse_burley, specular_schlick_ggx;

uniform vec4 cloth_color : source_color = vec4(0.953, 0.941, 0.906, 1.0);
uniform vec4 seam_color : source_color = vec4(0.835, 0.824, 0.788, 1.0);
uniform vec4 reinforcement_color : source_color = vec4(0.914, 0.898, 0.855, 1.0);
uniform sampler2D sail_logo : source_color, filter_linear_mipmap, repeat_disable;
uniform vec2 logo_center = vec2(0.5, 0.58);
uniform vec2 logo_size = vec2(0.98, 0.25);
uniform vec2 wireframe_grid = vec2(10.0, 26.0);
uniform vec3 logo_color : source_color = vec3(0.09, 0.29, 0.525);
uniform vec3 sail_normal_local = vec3(1.0, 0.0, 0.0);
uniform vec3 airflow_local = vec3(0.0, 0.0, 0.0);
uniform vec3 clew_delta_local = vec3(0.0, 0.0, 0.0);
uniform float sail_fill : hint_range(0.0, 1.0) = 0.0;
uniform float flutter_amount : hint_range(0.0, 1.0) = 0.0;
uniform float slack_amount : hint_range(0.0, 0.04) = 0.0;
uniform float maximum_billow_m : hint_range(0.0, 0.25) = 0.16;
uniform float animation_phase = 0.0;
uniform bool billow_enabled = true;
uniform bool wireframe_enabled = false;
uniform bool logo_enabled = true;

void vertex() {
	// Jib clew movement is a barycentric endpoint offset. Its head and tack stay
	// fixed, so the shader never tears the visual luff away from its rig anchors.
	float clew_weight = UV.x * (1.0 - UV.y);
	VERTEX += clew_delta_local * clew_weight;
	vec3 sail_normal = normalize(sail_normal_local);
	float flow_crossing = dot(normalize(airflow_local + vec3(0.00001)), sail_normal);
	float side_fade = smoothstep(0.015, 0.16, abs(flow_crossing));
	float leeward_side = sign(flow_crossing);
	float section_shape = sin(PI * UV.x) * sin(PI * UV.y) * mix(0.66, 1.0, UV.y);
	float slow_wave = sin(animation_phase * 1.35 + UV.y * 2.4 + UV.x * 1.8);
	float small_flutter = sin(animation_phase * 2.1 + UV.y * 4.0 + UV.x * 2.2) * 0.035;
	if (billow_enabled) {
		float stable_billow = maximum_billow_m * sail_fill * (1.0 + slow_wave * 0.045);
		float luffing_flutter = maximum_billow_m * flutter_amount * small_flutter;
		VERTEX += sail_normal * leeward_side * side_fade * (stable_billow + luffing_flutter + slack_amount * 0.12) * section_shape;
		VERTEX.y -= slack_amount * section_shape * 0.35;
	}
	NORMAL = sail_normal;
}

void fragment() {
	vec3 base_color = cloth_color.rgb;
	// Quiet panel seams, edge reinforcement and small corner patches read as
	// sewn fabric without adding texture maps or extra draw calls.
	float u_seam_distance = abs(fract(UV.x * 5.0) - 0.5);
	float v_seam_distance = abs(fract(UV.y * 6.0) - 0.5);
	float seam = max(1.0 - smoothstep(0.012, 0.028, u_seam_distance), 1.0 - smoothstep(0.012, 0.028, v_seam_distance));
	float edge_distance = min(min(UV.x, 1.0 - UV.x), min(UV.y, 1.0 - UV.y));
	seam = max(seam, 1.0 - smoothstep(0.003, 0.009, edge_distance));
	base_color = mix(base_color, seam_color.rgb, seam * 0.12);
	float head_patch = 1.0 - smoothstep(0.045, 0.065, distance(UV, vec2(0.0, 1.0)));
	float tack_patch = 1.0 - smoothstep(0.045, 0.065, distance(UV, vec2(0.0, 0.0)));
	float clew_patch = 1.0 - smoothstep(0.045, 0.065, distance(UV, vec2(1.0, 0.0)));
	base_color = mix(base_color, reinforcement_color.rgb, max(max(head_patch, tack_patch), clew_patch) * 0.65);
	float weave = sin(UV.x * 220.0) * sin(UV.y * 260.0);
	base_color *= 1.0 + weave * 0.006;

	vec2 logo_min = logo_center - logo_size * 0.5;
	vec2 logo_uv = (UV - logo_min) / logo_size;
	bool logo_in_region = all(greaterThanEqual(logo_uv, vec2(0.0))) && all(lessThanEqual(logo_uv, vec2(1.0)));
	if (logo_enabled && logo_in_region) {
		vec4 logo_sample = texture(sail_logo, vec2(logo_uv.x, 1.0 - logo_uv.y));
		base_color = mix(base_color, logo_color, logo_sample.a);
	}
	if (wireframe_enabled) {
		vec2 grid = abs(fract(UV * wireframe_grid) - 0.5);
		float grid_line = 1.0 - smoothstep(0.018, 0.050, min(grid.x, grid.y));
		base_color = mix(base_color, vec3(0.10, 0.31, 0.42), grid_line * 0.8);
	}
	ALBEDO = base_color;
	BACKLIGHT = base_color * 0.08;
	ROUGHNESS = 0.92;
	METALLIC = 0.0;
}
