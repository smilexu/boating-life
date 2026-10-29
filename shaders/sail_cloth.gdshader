shader_type spatial;
render_mode cull_disabled, diffuse_burley, specular_schlick_ggx;

uniform vec4 cloth_color : source_color = vec4(0.953, 0.941, 0.906, 1.0);
uniform vec4 seam_color : source_color = vec4(0.835, 0.824, 0.788, 1.0);
uniform vec4 reinforcement_color : source_color = vec4(0.914, 0.898, 0.855, 1.0);
uniform sampler2D sail_logo : source_color, filter_linear_mipmap, repeat_disable;
uniform vec2 logo_center = vec2(0.5, 0.58);
uniform vec2 logo_size = vec2(0.98, 0.25);
uniform vec2 wireframe_grid = vec2(20.0, 30.0);
uniform vec3 logo_color : source_color = vec3(0.09, 0.29, 0.525);
uniform vec3 sail_normal_local = vec3(1.0, 0.0, 0.0);
uniform vec3 sail_chord_tangent_local = vec3(0.0, 0.0, 1.0);
uniform vec3 clew_delta_local = vec3(0.0, 0.0, 0.0);
uniform vec2 sail_geometry_lengths_m = vec2(4.4, 8.0);
uniform float pressure_side_blend : hint_range(-1.0, 1.0) = 0.0;
uniform float deployment_fraction : hint_range(0.0, 1.0) = 1.0;
uniform float sail_fill : hint_range(0.0, 1.0) = 0.0;
uniform float flutter_amount : hint_range(0.0, 1.0) = 0.0;
uniform float strong_wind_tension : hint_range(0.0, 1.0) = 0.0;
uniform float slack_amount : hint_range(0.0, 0.04) = 0.0;
uniform float maximum_billow_m : hint_range(0.0, 1.2) = 0.90;
uniform float billow_time_variation : hint_range(0.0, 0.1) = 0.025;
uniform float leech_flutter_fraction : hint_range(0.0, 0.4) = 0.14;
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
	vec3 chord_tangent = normalize(sail_chord_tangent_local);
	vec3 luff_tangent = normalize(cross(chord_tangent, sail_normal));
	float u = UV.x;
	float v = UV.y;
	float sin_v = sin(PI * v);
	float cos_v = cos(PI * v);
	// A smooth beta-shaped chord profile peaks 38% aft of the luff and reaches
	// zero with zero slope at both edges. The vertical envelope also scales with
	// the shrinking triangular chord, keeping the head lighter than the foot.
	const float CHORD_POWER_FRONT = 2.0;
	const float CHORD_POWER_LEECH = 3.26;
	const float CHORD_PROFILE_NORMALIZER = 0.0304;
	const float VERTICAL_PROFILE_NORMALIZER = 0.509;
	float chord_curve = pow(u, CHORD_POWER_FRONT) * pow(max(1.0 - u, 0.0), CHORD_POWER_LEECH) / CHORD_PROFILE_NORMALIZER;
	float chord_curve_du = (
		CHORD_POWER_FRONT * pow(u, CHORD_POWER_FRONT - 1.0) * pow(max(1.0 - u, 0.0), CHORD_POWER_LEECH)
		- CHORD_POWER_LEECH * pow(u, CHORD_POWER_FRONT) * pow(max(1.0 - u, 0.0), CHORD_POWER_LEECH - 1.0)
	) / CHORD_PROFILE_NORMALIZER;
	float chord_taper = max(1.0 - v, 0.0);
	float panel_shape = 1.0 - 0.35 * v;
	float vertical_profile = chord_taper * sin_v * panel_shape / VERTICAL_PROFILE_NORMALIZER;
	float vertical_profile_dv = (
		-sin_v * panel_shape
		+ chord_taper * PI * cos_v * panel_shape
		- 0.35 * chord_taper * sin_v
	) / VERTICAL_PROFILE_NORMALIZER;
	float section_shape = chord_curve * vertical_profile;
	float section_du = chord_curve_du * vertical_profile;
	float section_dv = chord_curve * vertical_profile_dv;
	float slow_wave = sin(animation_phase * 0.8 + v * 2.0 + u * 1.5);
	float leech_flutter = sin(animation_phase * 2.0 + v * 3.7 + u * 5.0) * pow(u, 3.0) * sin_v;
	float deployment = clamp(deployment_fraction, 0.0, 1.0);
	float billow_amplitude = maximum_billow_m * deployment * sail_fill;
	billow_amplitude *= (1.0 + slow_wave * billow_time_variation) * (1.0 - strong_wind_tension * 0.10);
	float side = clamp(pressure_side_blend, -1.0, 1.0);
	float flutter_m = maximum_billow_m * deployment * flutter_amount * leech_flutter_fraction;
	flutter_m *= 1.0 - strong_wind_tension * 0.7;
	float surface_offset = side * (billow_amplitude * section_shape + flutter_m * leech_flutter);
	if (billow_enabled) {
		VERTEX += sail_normal * surface_offset;
		VERTEX.y -= slack_amount * deployment * section_shape * 0.35;
		float local_chord_m = max(sail_geometry_lengths_m.x * (1.0 - v), 0.12);
		float luff_length_m = max(sail_geometry_lengths_m.y, 0.12);
		float slope_u = side * billow_amplitude * section_du / local_chord_m;
		float slope_v = side * billow_amplitude * section_dv / luff_length_m;
		NORMAL = normalize(sail_normal - chord_tangent * slope_u - luff_tangent * slope_v);
		vec3 curved_tangent = chord_tangent + sail_normal * slope_u;
		TANGENT = normalize(curved_tangent - NORMAL * dot(curved_tangent, NORMAL));
		vec3 curved_binormal = luff_tangent + sail_normal * slope_v;
		curved_binormal -= NORMAL * dot(curved_binormal, NORMAL);
		curved_binormal -= TANGENT * dot(curved_binormal, TANGENT);
		BINORMAL = normalize(curved_binormal);
	} else {
		NORMAL = sail_normal;
		TANGENT = chord_tangent;
		BINORMAL = luff_tangent;
	}
}

void fragment() {
	if (!FRONT_FACING) {
		NORMAL = -NORMAL;
	}
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
