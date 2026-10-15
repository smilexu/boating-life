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
uniform float particle_opacity_min : hint_range(0.0, 1.0) = 0.78;
uniform float particle_opacity_max : hint_range(0.0, 1.0) = 1.0;

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
	float pattern = floor(patch_seed * 3.0);
	float style = fract(patch_seed * 3.0);
	vec2 stretch = vec2(
		mix(0.78, 1.18, fract(style * 1.73 + 0.2)),
		mix(0.76, 1.16, fract(style * 2.31 + 0.4))
	);
	centered *= stretch;
	float radial = length(centered);
	if (pattern < 0.5) {
		radial = length(centered * vec2(0.9, 1.08));
	} else if (pattern < 1.5) {
		float rounded_square = max(abs(centered.x), abs(centered.y) * 0.84);
		radial = mix(rounded_square, length(centered), 0.42);
	} else {
		radial = abs(centered.x) * 0.72 + abs(centered.y) * 0.58;
	}
	float noise_scale = mix(2.2, 4.45, pattern / 2.0);
	vec2 noise_uv = UV * noise_scale + vec2(patch_seed * 13.7, patch_seed * 29.3);
	float broad_noise = value_noise(noise_uv);
	float edge_noise = value_noise(noise_uv * mix(1.8, 2.45, style) + vec2(8.2, 3.7));
	float roughness = mix(0.13, 0.25, pattern / 2.0);
	float warped_radius = radial + (broad_noise - 0.5) * roughness + (edge_noise - 0.5) * 0.085;
	float edge_start = mix(0.58, 0.69, style);
	float silhouette = 1.0 - smoothstep(edge_start, 1.02, warped_radius);
	float patch_noise = broad_noise * 0.78 + edge_noise * 0.22;
	float threshold_variation = (style - 0.5) * 0.12;
	float foam_mask = smoothstep(foam_threshold + threshold_variation, foam_threshold + threshold_variation + foam_softness, patch_noise)
		* silhouette;
	float particle_variation = mix(particle_opacity_min, particle_opacity_max, fract(patch_seed * 7.13));
	float body_variation = mix(0.54, 0.94, broad_noise) * particle_variation;
	float body_alpha = silhouette * wake_opacity * body_variation;
	float foam_alpha = foam_mask * foam_opacity * particle_variation;
	vec3 varied_foam_tint = foam_tint * mix(0.9, 1.0, fract(patch_seed * 5.71));
	vec3 patch_color = mix(wake_tint, varied_foam_tint, foam_mask * 0.88);
	ALBEDO = patch_color * COLOR.rgb;
	ALPHA = clamp(max(body_alpha, foam_alpha) * COLOR.a, 0.0, 0.9);
}
