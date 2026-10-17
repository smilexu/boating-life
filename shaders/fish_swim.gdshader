shader_type spatial;
render_mode diffuse_burley, specular_schlick_ggx, cull_back;

uniform sampler2D albedo_texture : source_color, filter_linear_mipmap, repeat_enable;
uniform vec4 tint : source_color = vec4(1.0);
uniform float model_head_x = 0.5;
uniform float model_head_sign = 1.0;
uniform float model_length = 1.2;
uniform float wave_amplitude = 0.02;
uniform float tail_frequency_hz = 1.5;
uniform float surface_roughness = 0.68;
uniform bool animation_enabled = true;
uniform bool use_stickleback_body_tones = false;
uniform float dorsal_center_z = 0.0;
uniform float dorsal_half_span = 0.2;
uniform vec3 dorsal_tint_multiplier = vec3(0.68, 0.76, 0.82);
uniform vec3 belly_tint_multiplier = vec3(1.24, 1.28, 1.32);
uniform vec3 side_tint_multiplier = vec3(1.16, 1.18, 1.20);
uniform float dorsal_tone_strength = 0.32;
uniform float belly_tone_strength = 0.42;
uniform float side_tone_strength = 0.22;
varying vec4 fish_instance_data;
varying float fish_local_dorsal_position;

void vertex() {
	fish_instance_data = INSTANCE_CUSTOM;
	// The stickleback mesh uses local Z for its dorsal-to-belly axis. Capture the
	// undeformed position so the color gradient stays stable while its body swims.
	fish_local_dorsal_position = VERTEX.z;
	if (animation_enabled) {
		float tail = clamp((model_head_x - VERTEX.x) * model_head_sign / max(model_length, 0.01), 0.0, 1.0);
		float bend = smoothstep(0.08, 0.72, tail);
		float phase = INSTANCE_CUSTOM.x * 6.2831853;
		float amplitude_scale = mix(0.76, 1.26, INSTANCE_CUSTOM.y);
		float frequency_scale = mix(0.88, 1.16, INSTANCE_CUSTOM.z);
		float wave = sin(TIME * tail_frequency_hz * frequency_scale * 6.2831853 - tail * 2.55 + phase);
		// Species profiles provide the head end of the local X axis because GLB
		// exports are not consistent. Mesh-local Y is body width and Z is dorsal height.
		VERTEX.y += wave * wave_amplitude * amplitude_scale * bend * bend;
		VERTEX.z += sin(TIME * tail_frequency_hz * frequency_scale * 6.2831853 - tail * 2.05 + phase + 0.8)
			* wave_amplitude * 0.16 * bend * bend;
	}
}

void fragment() {
	float color_shift = fish_instance_data.w;
	vec3 individual_tint = vec3(1.0 + color_shift * 0.05, 1.0 + color_shift * 0.02, 1.0 - color_shift * 0.04);
	vec3 body_color = texture(albedo_texture, UV).rgb * tint.rgb * individual_tint;
	if (use_stickleback_body_tones) {
		float dorsal_position = clamp((fish_local_dorsal_position - dorsal_center_z) / max(dorsal_half_span, 0.001), -1.0, 1.0);
		float belly_mask = 1.0 - smoothstep(-0.72, -0.10, dorsal_position);
		float dorsal_mask = smoothstep(0.24, 0.86, dorsal_position);
		float side_mask = 1.0 - smoothstep(0.32, 0.78, abs(dorsal_position));
		vec3 body_tone = vec3(1.0);
		body_tone = mix(body_tone, dorsal_tint_multiplier, dorsal_mask * dorsal_tone_strength);
		body_tone = mix(body_tone, belly_tint_multiplier, belly_mask * belly_tone_strength);
		body_tone = mix(body_tone, side_tint_multiplier, side_mask * side_tone_strength);
		body_color *= body_tone;
	}
	ALBEDO = body_color;
	ROUGHNESS = surface_roughness;
	METALLIC = 0.0;
}
