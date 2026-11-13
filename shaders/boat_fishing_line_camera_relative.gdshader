shader_type spatial;
render_mode skip_vertex_transform, unshaded, cull_disabled, depth_draw_never;

instance uniform vec4 camera_relative_column_0 = vec4(1.0, 0.0, 0.0, 0.0);
instance uniform vec4 camera_relative_column_1 = vec4(0.0, 1.0, 0.0, 0.0);
instance uniform vec4 camera_relative_column_2 = vec4(0.0, 0.0, 1.0, 0.0);
instance uniform vec4 camera_relative_column_3 = vec4(0.0, 0.0, 0.0, 1.0);
uniform vec4 line_color : source_color = vec4(0.77, 0.86, 0.84, 0.95);

void vertex() {
	mat4 camera_relative_model = mat4(
		camera_relative_column_0,
		camera_relative_column_1,
		camera_relative_column_2,
		camera_relative_column_3
	);
	vec4 view_position = camera_relative_model * vec4(VERTEX, 1.0);
	VERTEX = view_position.xyz;
	POSITION = PROJECTION_MATRIX * view_position;
}

void fragment() {
	ALBEDO = line_color.rgb;
	ALPHA = line_color.a;
}
