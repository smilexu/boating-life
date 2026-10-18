shader_type spatial;
render_mode cull_disabled, depth_draw_opaque, diffuse_burley, specular_schlick_ggx;

varying vec4 instance_tint;

void vertex() {
	instance_tint = INSTANCE_CUSTOM;
}

void fragment() {
	if (!FRONT_FACING) {
		NORMAL = -NORMAL;
	}
	ALBEDO = COLOR.rgb * instance_tint.rgb;
	ROUGHNESS = 0.96;
	METALLIC = 0.0;
	SPECULAR = 0.04;
}
