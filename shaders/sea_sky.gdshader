shader_type sky;

uniform vec3 sky_top_color : source_color = vec3(0.055, 0.245, 0.56);
uniform vec3 sky_horizon_color : source_color = vec3(0.40, 0.64, 0.82);
uniform vec3 ground_bottom_color : source_color = vec3(0.12, 0.19, 0.25);
uniform vec3 ground_horizon_color : source_color = vec3(0.62, 0.75, 0.83);
uniform float sky_gradient_power : hint_range(0.1, 2.0) = 0.72;
uniform float ground_gradient_power : hint_range(0.1, 2.0) = 0.88;

// The disk is a sky-only HDR contribution. The DirectionalLight remains the
// source of scene illumination and keeps its authored energy and direction.
uniform vec3 sun_direction = vec3(0.0, 1.0, 0.0);
uniform vec3 sun_disk_color : source_color = vec3(1.0, 0.98, 0.92);
uniform float sun_energy : hint_range(0.0, 2.0) = 1.0;
uniform float sun_disk_radius_degrees : hint_range(0.1, 1.0) = 0.42;
uniform float sun_edge_softness_degrees : hint_range(0.01, 0.2) = 0.07;
uniform float sun_core_radiance : hint_range(0.0, 8.0) = 3.4;
uniform float sun_halo_strength : hint_range(0.0, 1.0) = 0.22;
uniform float sun_halo_radius_degrees : hint_range(1.0, 12.0) = 5.5;

uniform vec3 moon_direction = vec3(0.0, 1.0, 0.0);
uniform vec3 moon_disk_color : source_color = vec3(0.72, 0.82, 1.0);
uniform float moon_visibility : hint_range(0.0, 1.0) = 0.0;
uniform float moon_angular_radius_degrees : hint_range(0.1, 1.5) = 1.235;
uniform float moon_edge_softness_degrees : hint_range(0.005, 0.15) = 0.045;
uniform float moon_core_radiance : hint_range(0.1, 4.0) = 2.58;
uniform float moon_halo_strength : hint_range(0.0, 0.5) = 0.16;
uniform float moon_halo_radius_degrees : hint_range(0.5, 6.0) = 2.5;
uniform float moon_illumination_fraction : hint_range(0.0, 1.0) = 0.0;
uniform float star_strength : hint_range(0.0, 2.0) = 0.0;
uniform vec3 star_color : source_color = vec3(0.84, 0.90, 1.0);
uniform sampler2D starfield_texture : filter_linear, repeat_enable;

void sky() {
	float altitude = EYEDIR.y;
	if (altitude >= 0.0) {
		float sky_blend = pow(clamp(altitude, 0.0, 1.0), sky_gradient_power);
		COLOR = mix(sky_horizon_color, sky_top_color, sky_blend);
	} else {
		float ground_blend = pow(clamp(-altitude, 0.0, 1.0), ground_gradient_power);
		// Join the lower hemisphere to the exact upper-sky horizon color first.
		// Weather/day-night palettes intentionally use a different ground haze
		// color; applying it abruptly at EYEDIR.y == 0 creates a screen-wide
		// one-pixel seam when the ocean/terrain fades out near the horizon.
		float horizon_haze_mix = smoothstep(0.0, 0.035, -altitude);
		vec3 continuous_ground_horizon = mix(sky_horizon_color, ground_horizon_color, horizon_haze_mix);
		COLOR = mix(continuous_ground_horizon, ground_bottom_color, ground_blend);
	}

	float sun_alignment = dot(normalize(EYEDIR), normalize(sun_direction));
	float disk_radius = radians(sun_disk_radius_degrees);
	float disk_softness = radians(sun_edge_softness_degrees);
	float disk = smoothstep(
		cos(disk_radius + disk_softness),
		cos(max(disk_radius - disk_softness, 0.0)),
		sun_alignment
	);
	float halo_edge_cos = cos(radians(sun_halo_radius_degrees));
	float halo_amount = clamp((sun_alignment - halo_edge_cos) / max(1.0 - halo_edge_cos, 0.00001), 0.0, 1.0);
	float halo = pow(halo_amount, 2.0);
	COLOR += sun_disk_color * sun_energy * (disk * sun_core_radiance + halo * sun_halo_strength);

	vec3 moon_dir = normalize(moon_direction);
	float moon_alignment = dot(normalize(EYEDIR), moon_dir);
	float moon_radius = radians(moon_angular_radius_degrees);
	float moon_softness = radians(moon_edge_softness_degrees);
	float moon_disk = smoothstep(
		cos(moon_radius + moon_softness),
		cos(max(moon_radius - moon_softness, 0.0)),
		moon_alignment
	);
	if (moon_visibility > 0.0) {
		float moon_halo_edge = cos(radians(moon_halo_radius_degrees));
		float moon_halo = pow(clamp((moon_alignment - moon_halo_edge) / max(1.0 - moon_halo_edge, 0.00001), 0.0, 1.0), 2.5);
		float halo_phase = mix(0.24, 1.0, sqrt(clamp(moon_illumination_fraction, 0.0, 1.0)));
		COLOR += moon_disk_color * moon_visibility * moon_halo_strength * halo_phase * moon_halo;
	}
	if (moon_disk > 0.0 && moon_visibility > 0.0) {
		vec3 reference_axis = abs(moon_dir.y) < 0.92 ? vec3(0.0, 1.0, 0.0) : vec3(1.0, 0.0, 0.0);
		vec3 moon_right = normalize(cross(reference_axis, moon_dir));
		vec3 moon_up = normalize(cross(moon_dir, moon_right));
		float disk_sine = max(sin(moon_radius), 0.00001);
		vec2 moon_xy = vec2(dot(EYEDIR, moon_right), dot(EYEDIR, moon_up)) / disk_sine;
		float moon_r2 = min(dot(moon_xy, moon_xy), 1.0);
		vec3 lunar_surface_normal = normalize(-moon_dir * sqrt(max(1.0 - moon_r2, 0.0)) + moon_right * moon_xy.x + moon_up * moon_xy.y);
		float lunar_light = max(dot(lunar_surface_normal, normalize(sun_direction)), 0.0);
		float lunar_limb = 0.91 + 0.09 * sqrt(max(1.0 - moon_r2, 0.0));
		float maria = 0.94 + 0.06 * sin(moon_xy.x * 8.1 + moon_xy.y * 4.7) * sin(moon_xy.y * 5.3 - moon_xy.x * 2.2);
		float earthshine = 0.012 * (1.0 - moon_illumination_fraction);
		float lunar_surface = (earthshine + pow(lunar_light, 0.72)) * lunar_limb * maria;
		COLOR += moon_disk_color * moon_core_radiance * moon_visibility * moon_disk * lunar_surface;
	}
	if (star_strength > 0.001 && EYEDIR.y > 0.0) {
		vec2 star_uv = vec2(
			atan(EYEDIR.x, -EYEDIR.z) / 6.28318530718 + 0.5,
			asin(clamp(EYEDIR.y, -1.0, 1.0)) / 3.14159265359 + 0.5
		);
		float star_mask = texture(starfield_texture, star_uv).r;
		float horizon_visibility = smoothstep(0.005, 0.045, EYEDIR.y);
		COLOR += star_color * star_mask * star_strength * horizon_visibility;
	}
}
