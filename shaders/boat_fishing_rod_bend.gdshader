shader_type spatial;
render_mode cull_back;

uniform float bend_angle : hint_range(0.0, 0.8) = 0.0;
uniform float rod_length = 1.78;
uniform vec3 rod_color : source_color = vec3(0.07, 0.10, 0.12);

void vertex() {
	float s = clamp((VERTEX.y + rod_length * 0.5) / rod_length, 0.0, 1.0);
	float a = bend_angle * s;
	float safe_a = abs(bend_angle) < 0.0001 ? 1.0 : bend_angle;
	float center_x = abs(bend_angle) < 0.0001 ? 0.0 : rod_length * (1.0 - cos(a)) / safe_a;
	float center_y = abs(bend_angle) < 0.0001 ? -rod_length * 0.5 + rod_length * s : -rod_length * 0.5 + rod_length * sin(a) / safe_a;
	float lateral = VERTEX.x;
	VERTEX = vec3(
		center_x + lateral * cos(a),
		center_y - lateral * sin(a),
		VERTEX.z
	);
	NORMAL = normalize(vec3(
		NORMAL.x * cos(a) + NORMAL.y * sin(a),
		-NORMAL.x * sin(a) + NORMAL.y * cos(a),
		NORMAL.z
	));
}

void fragment() {
	ALBEDO = rod_color;
	ROUGHNESS = 0.28;
}
