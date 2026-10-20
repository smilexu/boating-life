shader_type spatial;
render_mode unshaded, blend_add, depth_draw_never, cull_disabled;

uniform sampler2D far_proxy_mask : filter_nearest, repeat_disable;
uniform vec3 warm_window_color : source_color = vec3(0.95, 0.66, 0.39);
uniform vec3 secondary_window_color : source_color = vec3(0.88, 0.91, 0.90);
uniform float secondary_color_ratio : hint_range(0.0, 1.0) = 0.12;
uniform float occupancy : hint_range(0.0, 0.8) = 0.3;
uniform float night_factor : hint_range(0.0, 1.0) = 0.0;
uniform float distance_fade : hint_range(0.0, 1.0) = 0.0;
uniform float emission_strength : hint_range(0.0, 8.0) = 3.8;
uniform float pattern_offset : hint_range(0.0, 1.0) = 0.0;

void fragment() {
	float raw_rank = texture(far_proxy_mask, UV).r;
	float has_window = step(0.004, raw_rank);
	float varied_rank = fract(raw_rank + pattern_offset);
	float selected = step(varied_rank, occupancy);
	float tone_seed = fract(raw_rank * 13.37 + pattern_offset * 7.13);
	float secondary_tone = step(1.0 - secondary_color_ratio, tone_seed);
	vec3 window_color = mix(warm_window_color, secondary_window_color, secondary_tone);
	float visible = has_window * selected * night_factor * distance_fade;
	ALBEDO = window_color;
	EMISSION = window_color * emission_strength;
	ALPHA = visible;
}
