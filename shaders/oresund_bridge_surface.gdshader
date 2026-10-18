shader_type spatial;
render_mode diffuse_burley, specular_schlick_ggx;

uniform vec4 base_color : source_color = vec4(0.65, 0.64, 0.60, 1.0);
uniform float metallic : hint_range(0.0, 1.0) = 0.0;
uniform float base_roughness : hint_range(0.0, 1.0) = 0.85;
uniform float variation_amount : hint_range(0.0, 0.2) = 0.05;
uniform float noise_scale : hint_range(0.001, 8.0) = 0.08;
uniform vec4 night_emission_color : source_color = vec4(0.0, 0.0, 0.0, 1.0);
uniform float night_emission_strength : hint_range(0.0, 0.5) = 0.0;

varying float surface_noise;


void vertex() {
	vec3 world_position = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz * noise_scale;
	float broad = sin(dot(world_position, vec3(0.173, 0.217, 0.139)));
	float detail = sin(dot(world_position, vec3(0.071, 0.113, 0.193)) + broad * 1.9);
	surface_noise = clamp(0.5 + (broad * 0.62 + detail * 0.38) * 0.5, 0.0, 1.0);
}


void fragment() {
	float color_shift = (surface_noise - 0.5) * variation_amount;
	ALBEDO = base_color.rgb * (1.0 + color_shift);
	METALLIC = metallic;
	ROUGHNESS = clamp(base_roughness + (surface_noise - 0.5) * 0.08, 0.0, 1.0);
	SPECULAR = 0.38;
	EMISSION = night_emission_color.rgb * night_emission_strength;
}
