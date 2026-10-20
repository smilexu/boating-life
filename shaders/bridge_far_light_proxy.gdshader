shader_type spatial;
// Distant bridge proxies use the CPU-fed weather-density fade once. Disable
// built-in depth fog here to avoid fading the same signal a second time.
render_mode unshaded, blend_add, depth_draw_never, cull_disabled, fog_disabled;

uniform vec3 proxy_color : source_color = vec3(1.0, 0.92, 0.82);
uniform float emission_strength : hint_range(0.0, 8.0) = 2.5;
uniform float night_strength : hint_range(0.0, 1.0) = 0.0;

varying float instance_strength;

void vertex() {
	instance_strength = INSTANCE_CUSTOM.r;
}

void fragment() {
	float radius = length(UV * 2.0 - vec2(1.0));
	float core = 1.0 - smoothstep(0.12, 0.72, radius);
	float halo = 0.16 * (1.0 - smoothstep(0.20, 1.0, radius));
	ALBEDO = vec3(0.0);
	EMISSION = proxy_color * emission_strength * night_strength * instance_strength;
	ALPHA = clamp(core + halo, 0.0, 1.0);
}
