shader_type spatial;
// Distant bridge proxies use the CPU-fed weather-density fade once. Disable
// built-in depth fog here to avoid fading the same signal a second time.
render_mode unshaded, blend_add, depth_draw_never, cull_disabled, fog_disabled;

uniform vec3 proxy_color : source_color = vec3(1.0, 0.94, 0.86);
uniform float emission_strength : hint_range(0.0, 8.0) = 5.2;
uniform float night_strength : hint_range(0.0, 1.0) = 0.0;

varying float instance_strength;

void vertex() {
	instance_strength = INSTANCE_CUSTOM.r;
}

void fragment() {
	ALBEDO = vec3(0.0);
	EMISSION = proxy_color * emission_strength * night_strength * instance_strength;
	ALPHA = 1.0;
}
