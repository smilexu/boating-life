class_name EngineAudioProfile
extends Resource

## Per-vessel engine sound and source-level tuning. Player volume remains global.

@export var profile_id: StringName = &""
@export var engine_stream: AudioStream
@export_range(-24.0, 24.0, 0.1) var playback_trim_db := 0.0
@export_range(0.0, 1.0, 0.01) var idle_gain := 0.18
@export_range(0.0, 1.0, 0.01) var throttle_gain := 0.62
@export_range(0.5, 1.5, 0.01) var minimum_pitch_scale := 0.86
@export_range(0.5, 1.5, 0.01) var maximum_pitch_scale := 1.13


func gain_for_power(power: float) -> float:
	return clampf(idle_gain + throttle_gain * clampf(power, 0.0, 1.0), 0.0, 1.0)


func pitch_for_power(power: float) -> float:
	return lerpf(minimum_pitch_scale, maximum_pitch_scale, clampf(power, 0.0, 1.0))
