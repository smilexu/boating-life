extends RefCounted

## NOAA fractional-year solar position approximation.
## Azimuth is clockwise from true north; the returned Godot vector follows the
## project's East-Up-South world frame (X=east, Y=up, -Z=north).

const WorldTimeManagerScript := preload("res://scripts/world_time_manager.gd")


static func calculate(date: Dictionary, local_seconds: float, latitude_deg: float, longitude_deg: float) -> Dictionary:
	if not WorldTimeManagerScript.is_valid_gregorian_date(
		int(date.get("year", 0)), int(date.get("month", 0)), int(date.get("day", 0))
	) or not is_finite(local_seconds):
		return {}

	var year := int(date["year"])
	var month := int(date["month"])
	var day := int(date["day"])
	var seconds := fposmod(local_seconds, 86400.0)
	var day_of_year := _day_of_year(year, month, day)
	var days_in_year := 366.0 if _is_leap_year(year) else 365.0
	var decimal_hour := seconds / 3600.0
	var fractional_year := TAU / days_in_year * (float(day_of_year - 1) + (decimal_hour - 12.0) / 24.0)
	var equation_of_time := 229.18 * (
		0.000075
		+ 0.001868 * cos(fractional_year)
		- 0.032077 * sin(fractional_year)
		- 0.014615 * cos(2.0 * fractional_year)
		- 0.040849 * sin(2.0 * fractional_year)
	)
	var declination := (
		0.006918
		- 0.399912 * cos(fractional_year)
		+ 0.070257 * sin(fractional_year)
		- 0.006758 * cos(2.0 * fractional_year)
		+ 0.000907 * sin(2.0 * fractional_year)
		- 0.002697 * cos(3.0 * fractional_year)
		+ 0.001480 * sin(3.0 * fractional_year)
	)
	var timezone_hours := float(WorldTimeManagerScript.stockholm_offset_seconds_for_civil_time(date, seconds)) / 3600.0
	var local_minutes := seconds / 60.0
	var time_offset := equation_of_time + 4.0 * longitude_deg - 60.0 * timezone_hours
	var true_solar_minutes := fposmod(local_minutes + time_offset, 1440.0)
	var hour_angle := deg_to_rad(true_solar_minutes / 4.0 - 180.0)
	var latitude := deg_to_rad(latitude_deg)
	var sin_latitude := sin(latitude)
	var cos_latitude := cos(latitude)
	var sin_declination := sin(declination)
	var cos_declination := cos(declination)
	var east := -cos_declination * sin(hour_angle)
	var north := cos_latitude * sin_declination - sin_latitude * cos_declination * cos(hour_angle)
	var up := sin_latitude * sin_declination + cos_latitude * cos_declination * cos(hour_angle)
	var horizontal_length := sqrt(east * east + north * north)
	var azimuth := fposmod(rad_to_deg(atan2(east, north)), 360.0)
	var elevation := rad_to_deg(atan2(up, horizontal_length))
	var godot_direction := Vector3(east, up, -north).normalized()
	var utc_timestamp := WorldTimeManagerScript.stockholm_civil_datetime_to_utc(date, seconds)
	return {
		"elevation_degrees": elevation,
		"azimuth_degrees": azimuth,
		"declination_degrees": rad_to_deg(declination),
		"equation_of_time_minutes": equation_of_time,
		"hour_angle_degrees": rad_to_deg(hour_angle),
		"timezone_offset_hours": timezone_hours,
		"utc_timestamp": utc_timestamp,
		"direction": godot_direction,
	}


static func _day_of_year(year: int, month: int, day: int) -> int:
	var month_lengths := [31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
	if _is_leap_year(year):
		month_lengths[1] = 29
	var total := day
	for month_index in range(month - 1):
		total += int(month_lengths[month_index])
	return total


static func _is_leap_year(year: int) -> bool:
	return year % 4 == 0 and (year % 100 != 0 or year % 400 == 0)
