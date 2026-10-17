shader_type spatial;
render_mode blend_mix, depth_draw_never, cull_disabled, diffuse_burley, specular_schlick_ggx;

uniform vec3 ripple_color : source_color = vec3(0.62, 0.82, 0.85);
varying vec4 ripple_data;

void vertex() {
	ripple_data = INSTANCE_CUSTOM;
}

void fragment() {
	vec2 centered_uv = UV * 2.0 - 1.0;
	float radial_distance = length(centered_uv);
	float period = mix(2.4, 4.0, ripple_data.g);
	float age = fract(TIME / period + ripple_data.r);
	float front = mix(0.12, 0.92, age);
	float width = mix(0.025, 0.055, ripple_data.a);
	float primary_ring = 1.0 - smoothstep(width, width + 0.022, abs(radial_distance - front));
	float trailing_ring = 1.0 - smoothstep(width * 0.7, width * 0.7 + 0.02, abs(radial_distance - max(front - 0.19, 0.08)));
	float edge_fade = smoothstep(0.05, 0.18, radial_distance) * (1.0 - smoothstep(0.86, 1.0, radial_distance));
	float age_fade = 0.32 + 0.68 * sin(age * 3.14159265);
	float pattern = max(primary_ring, trailing_ring * 0.55) * edge_fade;
	ALBEDO = ripple_color;
	ROUGHNESS = 0.28;
	SPECULAR = 0.48;
	ALPHA = pattern * age_fade * ripple_data.b * 0.56;
}
