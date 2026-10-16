shader_type spatial;
render_mode cull_back, diffuse_burley, specular_schlick_ggx;

uniform bool show_lod_debug = false;
uniform float color_variation_strength : hint_range(0.0, 0.35) = 0.12;
uniform float sand_ripple_strength : hint_range(0.0, 0.12) = 0.035;

varying vec3 world_position;
varying vec4 seabed_weights;


float hash_2d(vec2 p) {
	p = fract(p * vec2(123.34, 456.21));
	p += dot(p, p + 45.32);
	return fract(p.x * p.y);
}


float value_noise(vec2 p) {
	vec2 cell = floor(p);
	vec2 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	float a = hash_2d(cell);
	float b = hash_2d(cell + vec2(1.0, 0.0));
	float c = hash_2d(cell + vec2(0.0, 1.0));
	float d = hash_2d(cell + vec2(1.0, 1.0));
	return mix(mix(a, b, f.x), mix(c, d, f.x), f.y);
}


void vertex() {
	world_position = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	seabed_weights = COLOR;
}


void fragment() {
	vec3 weights = max(seabed_weights.rgb, vec3(0.0));
	float weight_sum = max(weights.r + weights.g + weights.b, 0.001);
	weights /= weight_sum;

	vec3 sand_color = vec3(0.46, 0.40, 0.31);
	vec3 mud_color = vec3(0.28, 0.33, 0.28);
	vec3 rock_color = vec3(0.31, 0.35, 0.39);
	vec3 seabed_color = sand_color * weights.r + mud_color * weights.g + rock_color * weights.b;

	vec2 world_xz = world_position.xz;
	float broad_variation = value_noise(world_xz * 0.009) - 0.5;
	float fine_variation = value_noise(world_xz * 0.065) - 0.5;
	float sand_ripple = sin(dot(world_xz, vec2(0.31, 0.12)) + broad_variation * 2.1);
	float variation = broad_variation * color_variation_strength
		+ fine_variation * color_variation_strength * 0.32
		+ sand_ripple * sand_ripple_strength * weights.r;

	if (show_lod_debug) {
		vec3 near_color = vec3(0.18, 0.72, 0.48);
		vec3 far_color = vec3(0.20, 0.43, 0.88);
		seabed_color = mix(far_color, near_color, smoothstep(0.25, 0.75, seabed_weights.a));
		variation = 0.0;
	}

	ALBEDO = max(seabed_color * (1.0 + variation), vec3(0.0));
	ROUGHNESS = 0.97;
	METALLIC = 0.0;
	SPECULAR = 0.035;
}
