shader_type spatial;
render_mode skip_vertex_transform, cull_back, diffuse_burley, specular_schlick_ggx;

instance uniform vec4 camera_relative_column_0 = vec4(1.0, 0.0, 0.0, 0.0);
instance uniform vec4 camera_relative_column_1 = vec4(0.0, 1.0, 0.0, 0.0);
instance uniform vec4 camera_relative_column_2 = vec4(0.0, 0.0, 1.0, 0.0);
instance uniform vec4 camera_relative_column_3 = vec4(0.0, 0.0, 0.0, 1.0);
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
	float tangent_along = dot(TANGENT, direction);
	float tangent_across = dot(TANGENT, side);
	float tangent_up = dot(TANGENT, up);
	float binormal_along = dot(BINORMAL, direction);
	float binormal_across = dot(BINORMAL, side);
	float binormal_up = dot(BINORMAL, up);
	NORMAL = normalize(
		direction * (normal_along * cos(a) + normal_up * sin(a))
		+ up * (-normal_along * sin(a) + normal_up * cos(a))
		+ side * normal_across
	);
	TANGENT = normalize(
		direction * (tangent_along * cos(a) + tangent_up * sin(a))
		+ up * (-tangent_along * sin(a) + tangent_up * cos(a))
		+ side * tangent_across
	);
	BINORMAL = normalize(
		direction * (binormal_along * cos(a) + binormal_up * sin(a))
		+ up * (-binormal_along * sin(a) + binormal_up * cos(a))
		+ side * binormal_across
	);
	mat4 camera_relative_model = mat4(
		camera_relative_column_0,
		camera_relative_column_1,
		camera_relative_column_2,
		camera_relative_column_3
	);
	mat3 camera_relative_basis = mat3(camera_relative_model);
	NORMAL = normalize(transpose(inverse(camera_relative_basis)) * NORMAL);
	TANGENT = normalize(camera_relative_basis * TANGENT);
	BINORMAL = normalize(camera_relative_basis * BINORMAL);
	vec4 view_position = camera_relative_model * vec4(VERTEX, 1.0);
	VERTEX = view_position.xyz;
	POSITION = PROJECTION_MATRIX * view_position;
}

void fragment() {
	ALBEDO = rod_color;
	ROUGHNESS = 0.28;
}
