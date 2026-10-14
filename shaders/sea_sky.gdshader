shader_type sky;

// Full-resolution cloud rendering keeps cumulus edges defined from the boat camera.
uniform vec4 sky_top_color : source_color = vec4(0.13, 0.38, 0.68, 1.0);
uniform vec4 sky_horizon_color : source_color = vec4(0.59, 0.77, 0.86, 1.0);
uniform vec4 atmosphere_haze_color : source_color = vec4(0.78, 0.84, 0.86, 1.0);
uniform vec4 cloud_light_color : source_color = vec4(0.93, 0.96, 0.97, 1.0);
uniform vec4 cloud_shadow_color : source_color = vec4(0.31, 0.43, 0.52, 1.0);

uniform float weather_type : hint_range(0.0, 2.0) = 0.0;
uniform float sun_elevation : hint_range(3.0, 75.0) = 10.0;
uniform float sun_azimuth : hint_range(0.0, 360.0) = 28.0;

uniform float main_cloud_coverage : hint_range(0.0, 1.0) = 0.25;
uniform float main_cloud_density : hint_range(0.0, 1.0) = 0.74;
uniform float main_cloud_scale : hint_range(0.25, 3.0) = 0.9;
uniform float main_cloud_softness : hint_range(0.0, 0.5) = 0.08;
uniform float main_cloud_brightness : hint_range(0.0, 1.5) = 1.05;
uniform float main_cloud_bottom_darkness : hint_range(0.0, 1.0) = 0.28;
uniform float main_cloud_speed : hint_range(0.0, 0.002) = 0.00018;
uniform vec2 main_cloud_direction = vec2(0.96, 0.28);

uniform float detail_cloud_coverage : hint_range(0.0, 1.0) = 0.09;
uniform float detail_cloud_density : hint_range(0.0, 1.0) = 0.33;
uniform float detail_cloud_scale : hint_range(0.25, 3.0) = 1.0;
uniform float detail_cloud_softness : hint_range(0.0, 0.5) = 0.12;
uniform float detail_cloud_brightness : hint_range(0.0, 1.5) = 0.83;
uniform float detail_cloud_bottom_darkness : hint_range(0.0, 1.0) = 0.16;
uniform float detail_cloud_speed : hint_range(0.0, 0.002) = 0.00024;
uniform vec2 detail_cloud_direction = vec2(0.28, 0.96);

uniform float overcast_coverage : hint_range(0.0, 1.0) = 0.91;
uniform float overcast_density : hint_range(0.0, 1.0) = 0.78;
uniform float overcast_scale : hint_range(0.25, 3.0) = 0.82;
uniform float overcast_softness : hint_range(0.0, 0.5) = 0.24;
uniform float overcast_brightness : hint_range(0.0, 1.5) = 0.79;
uniform float overcast_bottom_darkness : hint_range(0.0, 1.0) = 0.15;
uniform float overcast_speed : hint_range(0.0, 0.002) = 0.00012;
uniform vec2 overcast_direction = vec2(0.97, 0.24);
uniform float overcast_grayness : hint_range(0.0, 1.0) = 0.74;


float hash21_periodic(vec2 point, float horizontal_period) {
	point.x = mod(point.x, horizontal_period);
	return fract(sin(dot(point, vec2(127.1, 311.7))) * 43758.5453123);
}


float value_noise_2d(vec2 point, float horizontal_period) {
	vec2 cell = floor(point);
	vec2 local = fract(point);
	local = local * local * (3.0 - 2.0 * local);
	float lower = mix(hash21_periodic(cell, horizontal_period), hash21_periodic(cell + vec2(1.0, 0.0), horizontal_period), local.x);
	float upper = mix(hash21_periodic(cell + vec2(0.0, 1.0), horizontal_period), hash21_periodic(cell + vec2(1.0, 1.0), horizontal_period), local.x);
	return mix(lower, upper, local.y);
}


float fbm_2d(vec2 point, float horizontal_period) {
	float total = 0.0;
	float amplitude = 0.5;
	for (int octave = 0; octave < 4; octave++) {
		total += value_noise_2d(point, horizontal_period) * amplitude;
		point = point * 2.0 + vec2(17.0, 9.0);
		horizontal_period *= 2.0;
		amplitude *= 0.5;
	}
	return total / 0.9375;
}


vec2 sky_sphere_uv(vec3 direction) {
	return vec2(atan(direction.x, -direction.z) / TAU, asin(clamp(direction.y, -1.0, 1.0)) / PI + 0.5);
}


float puffy_cloud_field(vec2 point, float horizontal_period, float coverage, float softness, float seed, float region_coverage) {
	if (coverage <= 0.001) {
		return 0.0;
	}
	vec2 cell = floor(point);
	vec2 local = fract(point);
	float edge_warp = (fbm_2d(point * 2.0 + vec2(seed * 3.1 + 8.4, seed * 1.7 + 15.2), horizontal_period * 2.0) - 0.5) * 0.16;
	float edge_width = mix(0.025, 0.095, softness);
	float spawn_chance = clamp(coverage * mix(0.38, 1.62, region_coverage), 0.0, 0.95);
	float cloud_field = 0.0;
	for (int y = -1; y <= 1; y++) {
		for (int x = -1; x <= 1; x++) {
			vec2 offset = vec2(float(x), float(y));
			vec2 neighbor = cell + offset;
			float cell_roll = hash21_periodic(neighbor + vec2(seed * 7.7 + 23.7, seed * 2.9 + 8.3), horizontal_period);
			float cell_presence = smoothstep(cell_roll - 0.035, cell_roll + 0.035, spawn_chance);
			vec2 jitter = vec2(
				hash21_periodic(neighbor + vec2(seed * 1.3 + 11.7, 3.2), horizontal_period),
				hash21_periodic(neighbor + vec2(4.1, seed * 2.1 + 19.3), horizontal_period)
			) * 0.42 + vec2(0.29);
			vec2 delta = local - offset - jitter;
			float cloud_width = mix(0.82, 1.28, hash21_periodic(neighbor + vec2(23.7, seed * 1.9 + 8.3), horizontal_period));
			float cloud_height = mix(0.82, 1.12, hash21_periodic(neighbor + vec2(seed * 4.7 + 3.9, 27.1), horizontal_period));
			vec2 base_delta = vec2(delta.x / (0.72 * cloud_width), (delta.y + 0.10 * cloud_height) / (0.24 * cloud_height));
			float cloud_shape = 1.0 - smoothstep(0.78 - edge_width, 1.0 + edge_width, length(base_delta));
			for (int puff_index = 0; puff_index < 5; puff_index++) {
				float puff_id = float(puff_index);
				float puff_seed = puff_id * 5.7;
				float puff_size = mix(0.23, 0.34, hash21_periodic(neighbor + vec2(seed * 3.3 + puff_seed + 31.1, 12.7 + puff_seed), horizontal_period));
				float puff_variation = hash21_periodic(neighbor + vec2(7.3 + puff_seed, seed * 2.5 + 17.8), horizontal_period);
				float puff_offset = hash21_periodic(neighbor + vec2(19.1 + puff_seed, seed * 4.3 + 6.5), horizontal_period);
				float puff_x = (puff_id - 2.0) * 0.205 * cloud_width + (puff_offset - 0.5) * 0.10;
				float puff_y = (0.08 + (puff_variation - 0.5) * 0.40) * cloud_height;
				vec2 puff_delta = vec2(delta.x - puff_x, (delta.y - puff_y) / (0.80 * cloud_height));
				float puff = 1.0 - smoothstep(puff_size - edge_width, puff_size + edge_width + edge_warp, length(puff_delta));
				cloud_shape = max(cloud_shape, puff);
			}
			cloud_field = max(cloud_field, cloud_shape * cell_presence);
		}
	}
	return cloud_field;
}


vec2 sample_cumulus_layer(
		vec2 uv,
		float scale,
		float coverage,
		float density,
		float softness,
		float speed,
		vec2 wind_direction,
		float base_frequency,
		float vertical_frequency,
		float seed,
		float region_coverage) {
	float horizontal_cells = max(round((base_frequency / max(scale, 0.25)) / 4.0) * 4.0, 4.0);
	vec2 extent = vec2(horizontal_cells, vertical_frequency / max(scale, 0.25));
	vec2 wind = normalize(wind_direction + vec2(0.0001)) * TIME * speed * extent;
	vec2 point = uv * extent + wind;
	vec2 warp_point = point * 0.25 + vec2(seed * 3.7, seed * 8.1);
	vec2 warp = vec2(
		fbm_2d(warp_point, extent.x * 0.25),
		fbm_2d(warp_point + vec2(7.3, 19.1), extent.x * 0.25)
	) - vec2(0.5);
	point += warp * vec2(1.5, 1.1);
	float shape = puffy_cloud_field(point, extent.x, coverage, softness, seed, region_coverage);
	float mask = shape * density;
	return vec2(mask, shape);
}


vec2 sample_overcast_layer(vec2 uv) {
	float horizontal_cells = max(round((22.0 * overcast_scale) / 4.0) * 4.0, 4.0);
	vec2 extent = vec2(horizontal_cells, 13.0 * overcast_scale);
	vec2 wind = normalize(overcast_direction + vec2(0.0001)) * TIME * overcast_speed * extent;
	vec2 point = uv * extent + wind;
	vec2 warp_point = point * 0.25 + vec2(13.2, 5.7);
	vec2 warp = vec2(
		fbm_2d(warp_point, extent.x * 0.25),
		fbm_2d(warp_point + vec2(4.1, 17.8), extent.x * 0.25)
	) - vec2(0.5);
	point += warp * vec2(1.0, 0.65);
	float broad = fbm_2d(point, extent.x);
	float middle = fbm_2d(point * 2.0 + vec2(3.7, 8.9), extent.x * 2.0);
	float fine = fbm_2d(point * 4.0 + vec2(16.4, 2.1), extent.x * 4.0);
	float shape = clamp(0.5 + (mix(broad, middle, 0.46) - 0.5) * 2.1 + (fine - 0.5) * 0.38, 0.0, 1.0);
	float threshold = 0.76 - overcast_coverage * 0.45 - (overcast_density - 0.65) * 0.08;
	float edge_width = mix(0.025, 0.18, overcast_softness);
	float mask = smoothstep(threshold - edge_width, threshold + edge_width, shape) * overcast_density;
	return vec2(mask, shape);
}


vec3 light_cumulus(float shape, float detail, vec3 view_direction, vec3 sun_direction, float brightness, float bottom_darkness) {
	vec3 pseudo_normal = normalize(vec3((shape - 0.5) * 1.45, 0.75 + max(view_direction.y, 0.0) * 0.42, (detail - 0.5) * 1.25));
	float sun_diffuse = max(dot(pseudo_normal, sun_direction), 0.0);
	float sun_in_view = max(dot(view_direction, sun_direction), 0.0);
	float cloud_top = smoothstep(-0.06, 0.48, view_direction.y);
	float underside_shadow = bottom_darkness * (1.0 - cloud_top);
	float local_thickness = clamp((shape - 0.34) * 1.25 + detail * 0.20, 0.0, 0.35);
	float lighting = clamp(0.35 + sun_diffuse * 0.50 + sun_in_view * 0.14 + cloud_top * 0.18 + local_thickness - underside_shadow, 0.0, 1.0);
	return mix(cloud_shadow_color.rgb, cloud_light_color.rgb, lighting) * brightness;
}


void sky() {
	vec3 direction = normalize(EYEDIR);
	vec2 uv = sky_sphere_uv(direction);
	float horizon_fade = smoothstep(-0.16, 0.035, direction.y);
	float elevation = radians(sun_elevation);
	float azimuth = radians(sun_azimuth);
	vec3 sun_direction = normalize(vec3(sin(azimuth) * cos(elevation), sin(elevation), -cos(azimuth) * cos(elevation)));

	float sky_height = smoothstep(-0.07, 0.58, direction.y);
	vec3 sky_color = mix(sky_horizon_color.rgb, sky_top_color.rgb, pow(sky_height, 0.82));
	float haze_band = exp(-abs(direction.y - 0.008) * 21.0);
	sky_color = mix(sky_color, atmosphere_haze_color.rgb, haze_band * 0.43);
	float sun_facing = max(dot(direction, sun_direction), 0.0);
	sky_color += atmosphere_haze_color.rgb * pow(sun_facing, 9.0) * 0.12;

	if (LIGHT0_ENABLED) {
		float angular_size = max(LIGHT0_SIZE, 0.00436);
		float sun_disk = smoothstep(cos(angular_size * 0.75), cos(angular_size * 0.48), sun_facing);
		float solar_halo = pow(sun_facing, 95.0) * 0.28 + pow(sun_facing, 22.0) * 0.035;
		sky_color += LIGHT0_COLOR * (sun_disk * 1.4 + solar_halo) * max(LIGHT0_ENERGY, 0.2);
	}

	float overcast_blend = smoothstep(1.0, 2.0, weather_type);
	float cumulus_alpha = 0.0;
	vec3 cumulus_color = cloud_light_color.rgb;
	if (overcast_blend < 0.999) {
		vec2 organization_point = uv * vec2(16.0, 10.0) + normalize(main_cloud_direction + vec2(0.0001)) * TIME * main_cloud_speed * 1.5;
		float organization_raw = fbm_2d(organization_point, 16.0);
		float organization = clamp(0.5 + (organization_raw - 0.5) * 2.8, 0.0, 1.0);
		vec2 main_layer = sample_cumulus_layer(
			uv, main_cloud_scale, main_cloud_coverage, main_cloud_density, main_cloud_softness,
			main_cloud_speed, main_cloud_direction, 42.0, 28.0, 0.0, organization
		);
		vec2 detail_layer = sample_cumulus_layer(
			uv, detail_cloud_scale, detail_cloud_coverage, detail_cloud_density, detail_cloud_softness,
			detail_cloud_speed, detail_cloud_direction, 78.0, 52.0, 4.0, organization
		);
		float main_mask = main_layer.x;
		float detail_mask = detail_layer.x * (1.0 - main_mask * 0.82) * 0.38;
		cumulus_alpha = clamp(main_mask + detail_mask * 0.52, 0.0, 0.94) * horizon_fade;
		vec3 main_color = light_cumulus(main_layer.y, detail_layer.y, direction, sun_direction, main_cloud_brightness, main_cloud_bottom_darkness);
		vec3 detail_color = light_cumulus(detail_layer.y, main_layer.y, direction, sun_direction, detail_cloud_brightness, detail_cloud_bottom_darkness);
		cumulus_color = mix(main_color, detail_color, clamp(detail_mask * 0.30, 0.0, 0.18));
	}
	float overcast_alpha = 0.0;
	vec3 overcast_color = cloud_shadow_color.rgb;
	if (overcast_blend > 0.001) {
		vec2 sheet_layer = sample_overcast_layer(uv);
		overcast_alpha = sheet_layer.x * horizon_fade;
		float overcast_top = smoothstep(-0.08, 0.42, direction.y);
		float overcast_bottom_shadow = overcast_bottom_darkness * (1.0 - overcast_top);
		float overcast_lighting = clamp(0.35 + max(dot(direction, sun_direction), 0.0) * 0.12 + (sheet_layer.y - 0.44) * 1.25 - overcast_bottom_shadow, 0.0, 0.9);
		vec3 overcast_light = mix(cloud_shadow_color.rgb, cloud_light_color.rgb, overcast_lighting);
		float luminance = dot(overcast_light, vec3(0.299, 0.587, 0.114));
		overcast_color = mix(overcast_light, vec3(luminance), overcast_grayness) * overcast_brightness;
	}
	float cloud_alpha = mix(cumulus_alpha, overcast_alpha, overcast_blend);
	vec3 cloud_color = mix(cumulus_color, overcast_color, overcast_blend);
	COLOR = mix(sky_color, cloud_color, cloud_alpha);
}
