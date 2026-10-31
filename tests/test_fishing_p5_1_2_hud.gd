extends SceneTree

const PLAYER_PANEL := preload("res://scripts/fishing_player_panel.gd")
const NEEDLEFISH := preload("res://resources/fish_species/needlefish.tres")
const SURFACE_LURE := preload("res://resources/fishing/lures/surface_lure.tres")

var _failures: PackedStringArray = []


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var scan := {
		"surface_valid": true,
		"surface_height_world_y_m": 2.0,
		"probe_world_position": Vector3(0.0, 0.5, 0.0),
	}
	var echo := {
		"target_world_position": Vector3(1.0, -1.0, 0.0),
		"target_depth_below_transducer_m": 1.5,
		"depth_below_surface_m": 4.0,
	}
	var surface_depth := PLAYER_PANEL.echo_depth_below_surface_m(scan, echo)
	_check(is_equal_approx(surface_depth, 3.0), "Lure matching converts the echo target to the surface depth reference")
	_check(PLAYER_PANEL.classify_lure_depth(surface_depth, Vector2(2.0, 4.0)) == "match", "A lure overlapping the measured fish layer is classified as a match")
	_check(PLAYER_PANEL.classify_lure_depth(surface_depth, Vector2(0.0, 1.5)) == "too_shallow", "A lure shallower than the measured fish layer is identified")
	_check(PLAYER_PANEL.classify_lure_depth(surface_depth, Vector2(4.0, 6.0)) == "too_deep", "A lure deeper than the measured fish layer is identified")
	var fallback_scan := {
		"surface_valid": true,
		"surface_height_world_y_m": 2.0,
		"probe_world_position": Vector3(0.0, 0.5, 0.0),
	}
	var fallback_echo := {"target_depth_below_transducer_m": 1.5}
	_check(is_equal_approx(PLAYER_PANEL.echo_depth_below_surface_m(fallback_scan, fallback_echo), 3.0), "Legacy echo data uses probe depth to convert into a surface reference")
	_check(is_nan(PLAYER_PANEL.echo_depth_below_surface_m({"surface_valid": false}, echo)), "Invalid surface samples do not produce a lure depth match")
	var profiles: Array[FishSpeciesProfile] = [NEEDLEFISH]
	var suitable_speed := PLAYER_PANEL.classify_trolling_speed(1.6, 7.0, 0.25, profiles, SURFACE_LURE)
	var slow_speed := PLAYER_PANEL.classify_trolling_speed(0.5, 7.0, 0.25, profiles, SURFACE_LURE)
	var fast_speed := PLAYER_PANEL.classify_trolling_speed(3.0, 7.0, 0.25, profiles, SURFACE_LURE)
	var stationary_speed := PLAYER_PANEL.classify_trolling_speed(0.1, 7.0, 0.25, profiles, SURFACE_LURE)
	var over_cap_speed := PLAYER_PANEL.classify_trolling_speed(7.0, 7.0, 0.25, profiles, SURFACE_LURE)
	_check(suitable_speed.get("status") == "suitable" and is_equal_approx(float(suitable_speed.get("efficiency", 0.0)), 1.0), "Speed status uses the P2 species optimum and efficiency curve")
	_check(slow_speed.get("status") == "slow" and fast_speed.get("status") == "fast", "Speed direction is classified around the P2 species optimum")
	_check(stationary_speed.get("status") == "unavailable" and over_cap_speed.get("status") == "unavailable", "P2 minimum-speed and cruise-cap rules mark unusable speeds")
	print("Fishing P5.1/P5.2 HUD checks: %d failed" % _failures.size())
	for failure in _failures:
		push_error(failure)
	quit(1 if not _failures.is_empty() else 0)


func _check(condition: bool, label: String) -> void:
	if condition:
		print("PASS: %s" % label)
	else:
		_failures.append(label)
