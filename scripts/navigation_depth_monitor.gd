class_name NavigationDepthMonitor
extends Node

## Low-frequency, cached depth/draft status for the current boat and one lead point.

@export_node_path("Node") var provider_path := NodePath("../NavigationDepthProvider")
@export_node_path("Node3D") var boat_path := NodePath("../PlayerBoat/MotionRoot")
@export_range(0.1, 5.0, 0.1) var update_interval_seconds := 0.5
@export_range(0.5, 10.0, 0.1) var lookahead_seconds := 3.0
@export_range(2.0, 30.0, 1.0) var minimum_lookahead_m := 8.0
@export_range(10.0, 100.0, 1.0) var maximum_lookahead_m := 50.0

var _provider: NavigationDepthProvider
var _boat: BoatController
var _elapsed := 0.0
var _snapshot: Dictionary = {}


func _ready() -> void:
	_provider = get_node_or_null(provider_path) as NavigationDepthProvider
	_boat = get_node_or_null(boat_path) as BoatController
	_refresh_snapshot()


func _process(delta: float) -> void:
	_elapsed += delta
	if _elapsed < update_interval_seconds:
		return
	_elapsed = fmod(_elapsed, update_interval_seconds)
	_refresh_snapshot()


func get_snapshot() -> Dictionary:
	return _snapshot.duplicate(true)


func refresh_now() -> Dictionary:
	_refresh_snapshot()
	return get_snapshot()


func _refresh_snapshot() -> void:
	if _provider == null or _boat == null:
		_snapshot = {
			"status": NavigationDepthProvider.STATUS_UNKNOWN,
			"current": {"valid": false, "status": NavigationDepthProvider.STATUS_UNKNOWN, "data_state": "no_data", "reason": "Provider or boat missing"},
			"ahead": {"valid": false, "status": NavigationDepthProvider.STATUS_UNKNOWN, "data_state": "no_data", "reason": "Provider or boat missing"},
			"draft_m": -1.0,
			"safety_margin_m": 0.0,
			"lookahead_distance_m": 0.0,
			"warning": "Water depth is unknown",
		}
		return
	var draft := _boat.get_current_draft_m()
	if draft < 0.0:
		_snapshot = {
			"status": NavigationDepthProvider.STATUS_UNKNOWN,
			"current": {"valid": false, "status": NavigationDepthProvider.STATUS_UNKNOWN, "data_state": "no_data", "reason": "Vessel draft profile is not configured"},
			"ahead": {"valid": false, "status": NavigationDepthProvider.STATUS_UNKNOWN, "data_state": "no_data", "reason": "Vessel draft profile is not configured"},
			"draft_m": -1.0,
			"safety_margin_m": _provider.safety_margin_m,
			"lookahead_distance_m": 0.0,
			"warning": "Vessel draft is not configured; depth status is unknown",
		}
		return
	var forward := -_boat.global_transform.basis.z
	forward.y = 0.0
	if forward.length_squared() > 0.0001:
		forward = forward.normalized() * (1.0 if _boat.speed_mps >= 0.0 else -1.0)
	else:
		forward = Vector3.FORWARD
	var lookahead_distance := clampf(absf(_boat.speed_mps) * lookahead_seconds, minimum_lookahead_m, maximum_lookahead_m)
	var ahead_position := _boat.global_position + forward * lookahead_distance
	var current := _provider.evaluate_world_position(_boat.global_position, draft)
	var ahead := _provider.evaluate_world_position(ahead_position, draft)
	var status := NavigationDepthProvider.worse_status(
		str(current.get("status", NavigationDepthProvider.STATUS_UNKNOWN)),
		str(ahead.get("status", NavigationDepthProvider.STATUS_UNKNOWN))
	)
	var warning := ""
	if status == NavigationDepthProvider.STATUS_UNSAFE:
		warning = "Shallow water: reference depth is below vessel draft"
	elif status == NavigationDepthProvider.STATUS_CAUTION:
		warning = "Caution: depth does not meet the configured safety margin"
	elif status == NavigationDepthProvider.STATUS_UNKNOWN:
		warning = "Water depth is unknown; no safety assumption is made"
	_snapshot = {
		"status": status,
		"current": current,
		"ahead": ahead,
		"boat_position": _boat.global_position,
		"ahead_position": ahead_position,
		"draft_m": draft,
		"safety_margin_m": _provider.safety_margin_m,
		"lookahead_distance_m": lookahead_distance,
		"warning": warning,
	}
