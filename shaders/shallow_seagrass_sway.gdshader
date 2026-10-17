shader_type spatial;
render_mode cull_disabled, diffuse_burley, specular_schlick_ggx;

uniform bool sway_enabled = true;
uniform vec2 current_direction = vec2(0.92, 0.38);
uniform float current_speed = 0.18;
uniform float sway_strength = 0.12;

void vertex() {
	if (sway_enabled) {
		float height_weight = clamp(UV.y, 0.0, 1.0);
		float bend_weight = pow(height_weight, 2.25);
		float phase = TIME * (0.28 + current_speed * 0.42)
			+ INSTANCE_CUSTOM.x * 6.2831853
			+ UV.x * 0.72
			+ dot(VERTEX.xz, vec2(1.65, 1.15));
		float local_heading = (INSTANCE_CUSTOM.y - 0.5) * 0.72;
		vec2 flow = normalize(current_direction);
		flow = vec2(
			flow.x * cos(local_heading) - flow.y * sin(local_heading),
			flow.x * sin(local_heading) + flow.y * cos(local_heading)
		);
		vec2 cross_flow = vec2(-flow.y, flow.x);
		float wave_a = sin(phase + height_weight * 0.52);
		float wave_b = sin(phase * 0.71 + INSTANCE_CUSTOM.w * 6.2831853 + height_weight * 0.24);
		float amplitude = 0.82 + INSTANCE_CUSTOM.z * 0.32;
		float primary_bend = (wave_a * 0.78 + wave_b * 0.22) * sway_strength * amplitude * bend_weight;
		float lateral_bend = wave_b * sway_strength * 0.16 * bend_weight;
		VERTEX.xz += flow * primary_bend + cross_flow * lateral_bend;
	}
}

void fragment() {
	if (!FRONT_FACING) {
		NORMAL = -NORMAL;
	}
	ALBEDO = COLOR.rgb;
	ROUGHNESS = 0.90;
	METALLIC = 0.0;
	SPECULAR = 0.06;
}
