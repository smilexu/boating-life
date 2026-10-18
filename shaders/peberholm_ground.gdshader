shader_type spatial;
render_mode cull_front, depth_draw_opaque, diffuse_burley, specular_schlick_ggx;

varying vec3 world_position;

float hash_2d(vec2 point) {
	return fract(sin(dot(point, vec2(127.1, 311.7))) * 43758.5453123);
}

float value_noise(vec2 point) {
	vec2 cell = floor(point);
	vec2 blend = fract(point);
	blend = blend * blend * (3.0 - 2.0 * blend);
	float lower = mix(hash_2d(cell), hash_2d(cell + vec2(1.0, 0.0)), blend.x);
	float upper = mix(hash_2d(cell + vec2(0.0, 1.0)), hash_2d(cell + vec2(1.0, 1.0)), blend.x);
	return mix(lower, upper, blend.y);
}

float fbm(vec2 point) {
	float result = 0.0;
	float amplitude = 0.55;
	for (int octave = 0; octave < 4; octave++) {
		result += value_noise(point) * amplitude;
		point = point * 2.03 + vec2(17.2, 9.7);
		amplitude *= 0.5;
	}
	return result;
}

void vertex() {
	world_position = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

void fragment() {
	vec2 ground = world_position.xz;
	float broad = fbm(ground * 0.0045);
	float patch = fbm(ground * 0.018 + vec2(21.0, 7.0));
	float stone_field = fbm(ground * 0.052 + vec2(4.0, 31.0));
	float grain = value_noise(ground * 0.24 + vec2(63.0, 11.0));

	float gravel = smoothstep(0.43, 0.62, stone_field * 0.72 + patch * 0.28);
	gravel *= 0.66;
	float soil = smoothstep(0.42, 0.61, patch * 0.68 + broad * 0.32) * (1.0 - gravel) * 0.62;
	float grass = max(0.0, 1.0 - gravel - soil);

	vec3 grass_color = vec3(0.325, 0.395, 0.275);
	vec3 soil_color = vec3(0.425, 0.385, 0.315);
	vec3 gravel_color = vec3(0.475, 0.485, 0.445);
	vec3 color = grass_color * grass + soil_color * soil + gravel_color * gravel;
	color *= mix(0.91, 1.08, grain);
	color *= mix(0.94, 1.055, broad);

	ALBEDO = color;
	ROUGHNESS = 0.98;
	METALLIC = 0.0;
	SPECULAR = 0.08;
}
