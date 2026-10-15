// Test-only flat foam patches. The wave height calculation mirrors
// WaveSampler / sea_water.gdshader and reads the same wave resource and clock.
shader_type spatial;

render_mode blend_mix, depth_draw_never, cull_disabled, unshaded, world_vertex_coords;

uniform int wave_count = 0;
uniform float wave_steepness[8];
uniform float wave_amplitude[8];
uniform float wave_direction_degrees[8];
uniform float wave_frequency[8];
uniform float wave_speed[8];
uniform float wave_phase_degrees[8];
uniform float wave_time = 0.0;
uniform float water_plane_y = 0.0;
uniform vec3 camera_world_position = vec3(0.0, 0.0, 0.0);
uniform float surface_offset = 0.045;
uniform float vertex_wave_fade_min = 1400.0;
uniform float vertex_wave_fade_max = 1800.0;
uniform vec3 wake_tint : source_color = vec3(0.28, 0.62, 0.64);
uniform vec3 foam_tint : source_color = vec3(0.83, 0.92, 0.89);
uniform float wake_opacity : hint_range(0.0, 1.0) = 0.26;
uniform float foam_opacity : hint_range(0.0, 1.0) = 0.76;
uniform float foam_threshold : hint_range(0.0, 1.0) = 0.51;
uniform float foam_softness : hint_range(0.01, 0.5) = 0.14;

varying float patch_seed;

float hash_value(vec2 point) {
	vec3 p = fract(vec3(point.xyx) * vec3(0.1031, 0.1030, 0.0973));
	p += dot(p, p.yzx + 33.33);
	return fract((p.x + p.y) * p.z);
}

float value_noise(vec2 point) {
	vec2 cell = floor(point);
	vec2 f = fract(point);
	vec2 blend = f * f * (3.0 - 2.0 * f);
	float a = hash_value(cell);
	float b = hash_value(cell + vec2(1.0, 0.0));
	float c = hash_value(cell + vec2(0.0, 1.0));
	float d = hash_value(cell + vec2(1.0, 1.0));
	return mix(mix(a, b, blend.x), mix(c, d, blend.x), blend.y);
}

float wave_fade(vec2 source_xz) {
	vec3 base_position = vec3(source_xz.x, water_plane_y, source_xz.y);
	float camera_distance = distance(base_position, camera_world_position);
	if (vertex_wave_fade_max <= vertex_wave_fade_min) {
		return 1.0;
	}
	return 1.0 - smoothstep(vertex_wave_fade_min, vertex_wave_fade_max, camera_distance);
}

vec3 wave_displacement(vec2 source_xz, float fade) {
	vec3 displacement = vec3(0.0);
	for (int index = 0; index < wave_count; index++) {
		float direction_radians = wave_direction_degrees[index] * TAU / 360.0;
		vec2 direction = vec2(sin(direction_radians), cos(direction_radians));
		float phase = wave_phase_degrees[index] * TAU / 360.0;
		float theta = TAU * wave_frequency[index] * dot(direction, source_xz)
			+ wave_speed[index] * (wave_time + phase);
		float amplitude = wave_amplitude[index];
		displacement.x += wave_steepness[index] * amplitude * direction.x * cos(theta);
		displacement.y += wave_steepness[index] * sin(theta);
		displacement.z += wave_steepness[index] * amplitude * direction.y * cos(theta);
	}
	if (wave_count > 0) {
		displacement /= float(wave_count);
	}
	return displacement * fade;
}

void vertex() {
	vec2 target_xz = VERTEX.xz;
	vec2 source_xz = target_xz;
	// A single inverse step is sufficient for these small flat foam patches;
	// the CPU sampler retains its four-step solve for the hull's larger samples.
	for (int iteration = 0; iteration < 1; iteration++) {
		float fade = wave_fade(source_xz);
		vec3 displacement = wave_displacement(source_xz, fade);
		source_xz = target_xz - displacement.xz;
	}
	float fade = wave_fade(source_xz);
	vec3 displacement = wave_displacement(source_xz, fade);
	VERTEX.y = water_plane_y + displacement.y + surface_offset;
	patch_seed = fract(sin(INSTANCE_CUSTOM.x * 91.73 + 17.19) * 43758.5453);
}

void fragment() {
	vec2 centered = (UV - vec2(0.5)) * 2.0;
	float radius = length(centered);
	vec2 noise_uv = UV * 3.1 + vec2(patch_seed * 13.7, patch_seed * 29.3);
	float broad_noise = value_noise(noise_uv);
	float edge_noise = value_noise(noise_uv * 2.35 + vec2(8.2, 3.7));
	float warped_radius = radius + (broad_noise - 0.5) * 0.24 + (edge_noise - 0.5) * 0.09;
	float silhouette = 1.0 - smoothstep(0.63, 1.02, warped_radius);
	float patch_noise = broad_noise * 0.78 + edge_noise * 0.22;
	float foam_mask = smoothstep(foam_threshold, foam_threshold + foam_softness, patch_noise)
		* silhouette;
	float body_variation = mix(0.58, 1.0, broad_noise);
	float body_alpha = silhouette * wake_opacity * body_variation;
	float foam_alpha = foam_mask * foam_opacity;
	vec3 patch_color = mix(wake_tint, foam_tint, foam_mask * 0.88);
	ALBEDO = patch_color * COLOR.rgb;
	ALPHA = clamp(max(body_alpha, foam_alpha) * COLOR.a, 0.0, 0.9);
}
