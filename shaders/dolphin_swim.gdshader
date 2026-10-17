shader_type spatial;
render_mode diffuse_burley, specular_schlick_ggx;

uniform sampler2D albedo_texture : source_color, filter_linear_mipmap_anisotropic;
uniform sampler2D normal_texture : hint_normal, filter_linear_mipmap_anisotropic;
uniform sampler2D roughness_texture : filter_linear_mipmap_anisotropic;
uniform bool use_normal_texture = false;
uniform bool use_roughness_texture = false;
uniform float swim_time = 0.0;
uniform float swim_frequency = 0.9;
uniform float body_bend = 0.06;
uniform float animation_phase = 0.0;

void vertex() {
	// The GLB's nose is at local -X and its tail at +X. Its imported node maps
	// local Z to the vertical axis, so deforming Z gives the dolphin an up/down
	// tailbeat while keeping the head stable.
	float longitudinal = clamp((VERTEX.x + 0.5365) / 1.1874, 0.0, 1.0);
	float tail_weight = smoothstep(0.12, 0.86, longitudinal);
	float wave = sin(swim_time * 6.2831853 * swim_frequency - longitudinal * 5.1 + animation_phase);
	VERTEX.z += wave * body_bend * tail_weight;
}

void fragment() {
	vec4 albedo = texture(albedo_texture, UV);
	ALBEDO = albedo.rgb;
	ROUGHNESS = use_roughness_texture ? clamp(texture(roughness_texture, UV).g, 0.45, 0.88) : 0.74;
	METALLIC = 0.0;
	if (use_normal_texture) {
		NORMAL_MAP = texture(normal_texture, UV).rgb;
		NORMAL_MAP_DEPTH = 0.42;
	}
}
