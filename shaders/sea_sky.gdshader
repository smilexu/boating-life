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

void sky() {
	float altitude = EYEDIR.y;
	if (altitude >= 0.0) {
		float sky_blend = pow(clamp(altitude, 0.0, 1.0), sky_gradient_power);
		COLOR = mix(sky_horizon_color, sky_top_color, sky_blend);
	} else {
		float ground_blend = pow(clamp(-altitude, 0.0, 1.0), ground_gradient_power);
		COLOR = mix(ground_horizon_color, ground_bottom_color, ground_blend);
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
}
