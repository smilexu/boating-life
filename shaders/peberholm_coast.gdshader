shader_type spatial;
render_mode depth_draw_opaque, diffuse_burley, specular_schlick_ggx;

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

vec2 hash_22(vec2 point) {
	return vec2(
		hash_2d(point + vec2(13.4, 7.1)),
		hash_2d(point + vec2(83.2, 29.8))
	);
}

void vertex() {
	world_position = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

void fragment() {
	vec2 gravel_plane = world_position.xz * 0.78 + world_position.y * vec2(0.15, 0.11);
	vec2 cell = floor(gravel_plane);
	vec2 local = fract(gravel_plane);
	float nearest = 10.0;
	float second_nearest = 10.0;
	float stone_seed = 0.0;
	for (int y = -1; y <= 1; y++) {
		for (int x = -1; x <= 1; x++) {
			vec2 neighbor = vec2(float(x), float(y));
			vec2 random_offset = hash_22(cell + neighbor) * 0.76 + 0.12;
			float distance_to_stone = length(neighbor + random_offset - local);
			if (distance_to_stone < nearest) {
				second_nearest = nearest;
				nearest = distance_to_stone;
				stone_seed = hash_2d(cell + neighbor + vec2(9.0, 37.0));
			} else if (distance_to_stone < second_nearest) {
				second_nearest = distance_to_stone;
			}
		}
	}

	float broad = value_noise(world_position.xz * 0.065);
	float grain = value_noise(world_position.xz * 1.7 + vec2(14.0, 42.0));
	vec3 stone = mix(vec3(0.285, 0.305, 0.300), vec3(0.49, 0.48, 0.43), smoothstep(0.1, 0.9, stone_seed));
	stone *= mix(0.82, 1.12, broad);
	stone *= mix(0.94, 1.06, grain);
	float seams = 1.0 - smoothstep(0.045, 0.13, second_nearest - nearest);
	vec3 seam_color = vec3(0.19, 0.205, 0.20);
	ALBEDO = mix(stone, seam_color, seams * 0.34);
	ROUGHNESS = 0.98;
	METALLIC = 0.0;
	SPECULAR = 0.06;
}
