shader_type spatial;
render_mode cull_back;

uniform float bend_angle : hint_range(0.0, 0.8) = 0.0;
uniform float rod_length = 1.78;
uniform vec3 bend_direction_local = vec3(1.0, 0.0, 0.0);
uniform vec3 rod_color : source_color = vec3(0.07, 0.10, 0.12);

void vertex() {
	float s = clamp((VERTEX.y + rod_length * 0.5) / rod_length, 0.0, 1.0);
	float a = bend_angle * s;
	float safe_a = abs(bend_angle) < 0.0001 ? 1.0 : bend_angle;
	float center_distance = abs(bend_angle) < 0.0001 ? 0.0 : rod_length * (1.0 - cos(a)) / safe_a;
	float center_y = abs(bend_angle) < 0.0001 ? -rod_length * 0.5 + rod_length * s : -rod_length * 0.5 + rod_length * sin(a) / safe_a;
	vec3 up = vec3(0.0, 1.0, 0.0);
	vec3 direction = normalize(vec3(bend_direction_local.x, 0.0, bend_direction_local.z));
	vec3 side = normalize(cross(up, direction));
	vec3 radial = vec3(VERTEX.x, 0.0, VERTEX.z);
	float radial_along = dot(radial, direction);
	float radial_across = dot(radial, side);
	VERTEX = direction * (center_distance + radial_along * cos(a))
		+ up * (center_y - radial_along * sin(a))
		+ side * radial_across;
	float normal_along = dot(NORMAL, direction);
	float normal_across = dot(NORMAL, side);
	float normal_up = dot(NORMAL, up);
	NORMAL = normalize(
		direction * (normal_along * cos(a) + normal_up * sin(a))
		+ up * (-normal_along * sin(a) + normal_up * cos(a))
		+ side * normal_across
	);
}

void fragment() {
	ALBEDO = rod_color;
	ROUGHNESS = 0.28;
}
