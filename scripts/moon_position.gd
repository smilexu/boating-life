extends RefCounted

## Low-precision lunar ephemeris for the Øresund prototype.
## The lunar orbital phase is sampled at local noon of the world-calendar date,
## so accelerated day cycles on the same date keep the same lunar phase. The
## local hour angle follows cycle_seconds, giving a continuous sky path in each
## game day-cycle. All coordinates use the project's East-Up-South frame.

const WorldTimeManagerScript := preload("res://scripts/world_time_manager.gd")
const UNIX_EPOCH_JULIAN_DAY := 2440587.5
const J2000_JULIAN_DAY := 2451545.0


static func calculate(date: Dictionary, cycle_seconds: float, latitude_deg: float, longitude_deg: float) -> Dictionary:
	if not WorldTimeManagerScript.is_valid_gregorian_date(
		int(date.get("year", 0)), int(date.get("month", 0)), int(date.get("day", 0))
	) or not is_finite(cycle_seconds):
		return {}

	var date_noon_utc := WorldTimeManagerScript.stockholm_civil_datetime_to_utc(date, 12.0 * 3600.0)
	var current_utc := WorldTimeManagerScript.stockholm_civil_datetime_to_utc(date, cycle_seconds)
	var phase_julian_day := float(date_noon_utc) / 86400.0 + UNIX_EPOCH_JULIAN_DAY
	var current_julian_day := float(current_utc) / 86400.0 + UNIX_EPOCH_JULIAN_DAY
	var days_since_epoch := phase_julian_day - 2451543.5
	var moon_elements := _moon_ecliptic_position(days_since_epoch)
	var sun_longitude := _sun_ecliptic_longitude(days_since_epoch)
	var elongation := fposmod(float(moon_elements.longitude_degrees) - sun_longitude, 360.0)
	var illumination := clampf((1.0 - cos(deg_to_rad(elongation))) * 0.5, 0.0, 1.0)
	var phase_name := _phase_name(elongation)
	var equatorial := _ecliptic_to_equatorial(
		float(moon_elements.longitude_degrees),
		float(moon_elements.latitude_degrees),
		23.439291 - 0.0130042 * ((phase_julian_day - J2000_JULIAN_DAY) / 36525.0)
	)
	var right_ascension := float(equatorial.right_ascension_degrees)
	var declination := float(equatorial.declination_degrees)
	var sidereal_degrees := _greenwich_mean_sidereal_degrees(current_julian_day) + longitude_deg
	var hour_angle_degrees := _wrap_signed_degrees(sidereal_degrees - right_ascension)
	var latitude := deg_to_rad(latitude_deg)
	var hour_angle := deg_to_rad(hour_angle_degrees)
	var declination_radians := deg_to_rad(declination)
	var east := -cos(declination_radians) * sin(hour_angle)
	var north := cos(latitude) * sin(declination_radians) - sin(latitude) * cos(declination_radians) * cos(hour_angle)
	var up := sin(latitude) * sin(declination_radians) + cos(latitude) * cos(declination_radians) * cos(hour_angle)
	var horizontal_length := sqrt(east * east + north * north)
	var elevation := rad_to_deg(atan2(up, horizontal_length))
	var azimuth := fposmod(rad_to_deg(atan2(east, north)), 360.0)
	return {
		"elevation_degrees": elevation,
		"azimuth_degrees": azimuth,
		"direction": Vector3(east, up, -north).normalized(),
		"illumination_fraction": illumination,
		"phase_angle_degrees": elongation,
		"phase_name": phase_name,
		"waxing": elongation < 180.0,
		"right_ascension_degrees": right_ascension,
		"declination_degrees": declination,
		"hour_angle_degrees": hour_angle_degrees,
		"world_date": {"year": int(date["year"]), "month": int(date["month"]), "day": int(date["day"])},
		"orbital_sample": "Europe/Stockholm world-calendar date at local noon",
		"sky_track_sample": "day-cycle local time converted with Europe/Stockholm offset",
	}


static func _moon_ecliptic_position(days: float) -> Dictionary:
	var ascending_node := deg_to_rad(fposmod(125.1228 - 0.0529538083 * days, 360.0))
	var inclination := deg_to_rad(5.1454)
	var argument_periapsis := deg_to_rad(fposmod(318.0634 + 0.1643573223 * days, 360.0))
	var eccentricity := 0.0549
	var mean_anomaly_degrees := fposmod(115.3654 + 13.0649929509 * days, 360.0)
	var mean_anomaly := deg_to_rad(mean_anomaly_degrees)
	var eccentric_anomaly := mean_anomaly + eccentricity * sin(mean_anomaly) * (1.0 + eccentricity * cos(mean_anomaly))
	for _iteration in range(3):
		eccentric_anomaly -= (eccentric_anomaly - eccentricity * sin(eccentric_anomaly) - mean_anomaly) / (1.0 - eccentricity * cos(eccentric_anomaly))
	var xv := cos(eccentric_anomaly) - eccentricity
	var yv := sqrt(1.0 - eccentricity * eccentricity) * sin(eccentric_anomaly)
	var true_anomaly := atan2(yv, xv)
	var radius := sqrt(xv * xv + yv * yv)
	var orbital_angle := true_anomaly + argument_periapsis
	var x := radius * (cos(ascending_node) * cos(orbital_angle) - sin(ascending_node) * sin(orbital_angle) * cos(inclination))
	var y := radius * (sin(ascending_node) * cos(orbital_angle) + cos(ascending_node) * sin(orbital_angle) * cos(inclination))
	var z := radius * sin(orbital_angle) * sin(inclination)
	var longitude := rad_to_deg(atan2(y, x))
	var latitude := rad_to_deg(atan2(z, sqrt(x * x + y * y)))
	var sun_mean_anomaly := deg_to_rad(fposmod(356.0470 + 0.9856002585 * days, 360.0))
	var sun_mean_longitude := fposmod(rad_to_deg(sun_mean_anomaly) + 282.9404 + 4.70935e-5 * days, 360.0)
	var moon_mean_longitude := fposmod(125.1228 - 0.0529538083 * days + 318.0634 + 0.1643573223 * days + mean_anomaly_degrees, 360.0)
	var elongation := deg_to_rad(fposmod(moon_mean_longitude - sun_mean_longitude, 360.0))
	var argument_latitude := deg_to_rad(fposmod(moon_mean_longitude - rad_to_deg(ascending_node), 360.0))
	# Leading periodic terms capture the main evection, variation, and latitude
	# corrections without adding ephemeris tables or render-time work.
	longitude += (
		-1.274 * sin(mean_anomaly - 2.0 * elongation)
		+ 0.658 * sin(2.0 * elongation)
		- 0.186 * sin(sun_mean_anomaly)
		- 0.059 * sin(2.0 * mean_anomaly - 2.0 * elongation)
		- 0.057 * sin(mean_anomaly - 2.0 * elongation + sun_mean_anomaly)
		+ 0.053 * sin(mean_anomaly + 2.0 * elongation)
		+ 0.046 * sin(2.0 * elongation - sun_mean_anomaly)
		+ 0.041 * sin(mean_anomaly - sun_mean_anomaly)
		- 0.035 * sin(elongation)
		- 0.031 * sin(mean_anomaly + sun_mean_anomaly)
		- 0.015 * sin(2.0 * argument_latitude - 2.0 * elongation)
		+ 0.011 * sin(mean_anomaly - 4.0 * elongation)
	)
	latitude += (
		-0.173 * sin(argument_latitude - 2.0 * elongation)
		- 0.055 * sin(mean_anomaly - argument_latitude - 2.0 * elongation)
		- 0.046 * sin(mean_anomaly + argument_latitude - 2.0 * elongation)
		+ 0.033 * sin(argument_latitude + 2.0 * elongation)
		+ 0.017 * sin(2.0 * mean_anomaly + argument_latitude)
	)
	return {"longitude_degrees": fposmod(longitude, 360.0), "latitude_degrees": latitude}


static func _sun_ecliptic_longitude(days: float) -> float:
	var mean_anomaly_degrees := fposmod(356.0470 + 0.9856002585 * days, 360.0)
	var mean_anomaly := deg_to_rad(mean_anomaly_degrees)
	var eccentricity := 0.016709 - 1.151e-9 * days
	var eccentric_anomaly := mean_anomaly + eccentricity * sin(mean_anomaly) * (1.0 + eccentricity * cos(mean_anomaly))
	var true_anomaly := atan2(sqrt(1.0 - eccentricity * eccentricity) * sin(eccentric_anomaly), cos(eccentric_anomaly) - eccentricity)
	var perihelion := deg_to_rad(282.9404 + 4.70935e-5 * days)
	return fposmod(rad_to_deg(true_anomaly + perihelion), 360.0)


static func _ecliptic_to_equatorial(longitude_degrees: float, latitude_degrees: float, obliquity_degrees: float) -> Dictionary:
	var longitude := deg_to_rad(longitude_degrees)
	var latitude := deg_to_rad(latitude_degrees)
	var obliquity := deg_to_rad(obliquity_degrees)
	var x := cos(latitude) * cos(longitude)
	var y := cos(latitude) * sin(longitude) * cos(obliquity) - sin(latitude) * sin(obliquity)
	var z := cos(latitude) * sin(longitude) * sin(obliquity) + sin(latitude) * cos(obliquity)
	return {
		"right_ascension_degrees": fposmod(rad_to_deg(atan2(y, x)), 360.0),
		"declination_degrees": rad_to_deg(asin(clampf(z, -1.0, 1.0))),
	}


static func _greenwich_mean_sidereal_degrees(julian_day: float) -> float:
	var centuries := (julian_day - J2000_JULIAN_DAY) / 36525.0
	return fposmod(
		280.46061837
		+ 360.98564736629 * (julian_day - J2000_JULIAN_DAY)
		+ 0.000387933 * centuries * centuries
		- centuries * centuries * centuries / 38710000.0,
		360.0
	)


static func _phase_name(elongation_degrees: float) -> String:
	if elongation_degrees < 22.5 or elongation_degrees >= 337.5:
		return "New Moon"
	if elongation_degrees < 67.5:
		return "Waxing Crescent"
	if elongation_degrees < 112.5:
		return "First Quarter"
	if elongation_degrees < 157.5:
		return "Waxing Gibbous"
	if elongation_degrees < 202.5:
		return "Full Moon"
	if elongation_degrees < 247.5:
		return "Waning Gibbous"
	if elongation_degrees < 292.5:
		return "Last Quarter"
	return "Waning Crescent"


static func _wrap_signed_degrees(angle_degrees: float) -> float:
	return fposmod(angle_degrees + 180.0, 360.0) - 180.0
