shader_type spatial;
render_mode skip_vertex_transform, cull_back, diffuse_burley, specular_schlick_ggx;

instance uniform vec4 camera_relative_column_0 = vec4(1.0, 0.0, 0.0, 0.0);
instance uniform vec4 camera_relative_column_1 = vec4(0.0, 1.0, 0.0, 0.0);
instance uniform vec4 camera_relative_column_2 = vec4(0.0, 0.0, 1.0, 0.0);
instance uniform vec4 camera_relative_column_3 = vec4(0.0, 0.0, 0.0, 1.0);
instance uniform vec4 albedo_color : source_color = vec4(0.5, 0.5, 0.5, 1.0);
instance uniform float metallic_value = 0.0;
instance uniform float roughness_value = 0.5;

void vertex() {
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
	ALBEDO = albedo_color.rgb;
	METALLIC = metallic_value;
	ROUGHNESS = roughness_value;
}
