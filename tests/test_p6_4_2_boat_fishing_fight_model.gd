extends SceneTree

const PROFILE_CATALOG := preload("res://scripts/boat_fishing_fight_profile_catalog.gd")
const PARTICIPANT_SCRIPT := preload("res://scripts/boat_fishing_fight_participant.gd")
const PENDING_CATCH_SCRIPT := preload("res://scripts/fishing_pending_catch.gd")

const SPECIES_RESOURCE_PATHS := {
	"herring": "res://resources/fish_species/herring.tres",
	"sea_trout": "res://resources/fish_species/sea_trout.tres",
	"needlefish": "res://resources/fish_species/needlefish.tres",
}

var _failures := 0


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	_test_profiles_and_size_scaling()
	_test_identity_and_seed_reproducibility()
	_test_struggle_and_stamina()
	_test_five_independent_participants()
	_test_large_dt_and_frame_partitioning()
	_test_direction_constraints_and_independence()
	print("[P6.4.2] failures=%d" % _failures)
	quit(1 if _failures > 0 else 0)


func _test_profiles_and_size_scaling() -> void:
	for species_id in SPECIES_RESOURCE_PATHS:
		var species := load(str(SPECIES_RESOURCE_PATHS[species_id])) as FishSpeciesProfile
		var profile := PROFILE_CATALOG.load_profile(species_id)
		_check(species != null, "%s species resource loads" % species_id)
		_check(profile != null and profile.species_id == species_id, "%s boat-fishing fight profile loads" % species_id)
		if species == null or profile == null:
			continue
		var low_length := profile.get_size_factor(species.body_length_range_m.x)
		var high_length := profile.get_size_factor(species.body_length_range_m.y)
		_check(high_length > low_length, "%s larger body produces greater size factor" % species_id)
		_check(is_finite(profile.get_size_factor(0.0)) and is_finite(profile.get_size_factor(NAN)), "%s invalid body length safely falls back" % species_id)
		_check(profile.get_bounded_pull_n(INF) <= profile.maximum_pull_n and profile.get_bounded_pull_n(-INF) >= 0.0, "%s force bounds reject infinite outputs" % species_id)

	var herring := PROFILE_CATALOG.load_profile("herring")
	var trout := PROFILE_CATALOG.load_profile("sea_trout")
	var needlefish := PROFILE_CATALOG.load_profile("needlefish")
	_check(herring.base_pull_n < needlefish.base_pull_n and needlefish.base_pull_n < trout.base_pull_n, "species reference pulls are ordered herring < needlefish < sea trout")
	_check(herring.burst_interval_max_s < trout.burst_interval_min_s, "herring struggle rhythm is more frequent than sea trout")


func _test_identity_and_seed_reproducibility() -> void:
	var pending := _make_pending("catch-stable-17", "herring", 0.41, 2, true)
	var profile := PROFILE_CATALOG.load_profile("herring")
	var first := _make_participant(pending, profile, 98231, Vector3(1.0, 0.0, 0.0))
	var second := _make_participant(pending, profile, 98231, Vector3(1.0, 0.0, 0.0))
	var initial: Dictionary = first.get_read_only_snapshot()
	_check(initial.get("catch_id") == pending.catch_id and initial.get("hook_index") == pending.hook_index, "participant preserves catch identity and hook index")
	_check(initial.get("species_id") == pending.species_id and initial.get("body_length_m") == pending.body_length_m, "participant preserves species and rolled body length")
	_check(initial.get("debug_spawned") == pending.debug_spawned, "participant preserves debug-spawn marker")
	for dt in [0.13, 0.27, 0.05, 0.61, 1.4, 0.08, 2.2]:
		first.advance(float(dt), Vector3(1.0, 0.0, 0.0))
		second.advance(float(dt), Vector3(1.0, 0.0, 0.0))
	_check(_snapshots_match(first.get_read_only_snapshot(), second.get_read_only_snapshot()), "same catch, seed and real-dt sequence reproduce the same struggle")
	var derived_a := _make_participant(_make_pending("catch-A", "herring", 0.3), profile)
	var derived_b := _make_participant(_make_pending("catch-B", "herring", 0.3), profile)
	_check(derived_a.get_read_only_snapshot().get("fight_seed") != derived_b.get_read_only_snapshot().get("fight_seed"), "different catch IDs derive independent random seeds")
	var zero_seed_a := _make_participant(pending, profile, 0)
	var zero_seed_b := _make_participant(pending, profile, 0)
	zero_seed_a.advance(3.0)
	zero_seed_b.advance(3.0)
	_check(_snapshots_match(zero_seed_a.get_read_only_snapshot(), zero_seed_b.get_read_only_snapshot()), "zero is accepted as a deterministic explicit seed")
	var copy: Dictionary = first.get_read_only_snapshot()
	copy["stamina_ratio"] = -999.0
	_check(float(first.get_read_only_snapshot().get("stamina_ratio")) >= 0.0, "snapshot is a detached read-only value copy")
	_check(not first.initialize_from_pending_catch(pending, profile, 11), "initialized participant cannot be rebound to a different catch session")
	var unhooked := _make_pending("catch-not-yet-hooked", "herring", 0.3)
	unhooked.hook_confirmed = false
	var invalid_participant := PARTICIPANT_SCRIPT.new() as BoatFishingFightParticipant
	_check(not invalid_participant.initialize_from_pending_catch(unhooked, profile), "approach reservation cannot start a fight before hook confirmation")
	var trolling_pending := _make_pending("trolling-catch", "herring", 0.3)
	trolling_pending.fishing_method = "trolling"
	_check(not invalid_participant.initialize_from_pending_catch(trolling_pending, profile), "trolling catch cannot enter the boat-fishing participant")


func _test_struggle_and_stamina() -> void:
	var pending := _make_pending("catch-struggle", "herring", 0.3)
	var profile := PROFILE_CATALOG.load_profile("herring")
	var participant := _make_participant(pending, profile, 35519, Vector3(1.0, 0.0, 0.0))
	var initial: Dictionary = participant.get_read_only_snapshot()
	var initial_pull := float(initial.get("current_pull_n", 0.0))
	var max_pull := initial_pull
	var min_stamina := 1.0
	var saw_burst := false
	var saw_recovery_gain := false
	var previous_state := str(initial.get("struggle_state", ""))
	var outputs_finite := true
	var stamina_clamped := true
	for _index in range(1800):
		var state_before: Dictionary = participant.get_read_only_snapshot()
		var state_name := str(state_before.get("struggle_state", ""))
		var stamina_before := float(state_before.get("stamina_ratio", 1.0))
		participant.advance(0.025, Vector3(1.0, 0.0, 0.0))
		var snapshot: Dictionary = participant.get_read_only_snapshot()
		max_pull = maxf(max_pull, float(snapshot.get("current_pull_n", 0.0)))
		min_stamina = minf(min_stamina, float(snapshot.get("stamina_ratio", 1.0)))
		outputs_finite = outputs_finite and is_finite(float(snapshot.get("current_pull_n", NAN))) and float(snapshot.get("current_pull_n", -1.0)) >= 0.0
		stamina_clamped = stamina_clamped and float(snapshot.get("stamina_ratio", -1.0)) >= 0.0 and float(snapshot.get("stamina_ratio", 2.0)) <= 1.0
		if state_name == "burst":
			saw_burst = true
		if state_name == "recovery" and float(snapshot.get("stamina_ratio", 0.0)) > stamina_before:
			saw_recovery_gain = true
		previous_state = state_name
	_check(outputs_finite, "force remains finite and nonnegative during struggle")
	_check(stamina_clamped, "stamina remains clamped to [0, 1]")
	_check(saw_burst and max_pull > initial_pull, "burst produces a stronger pull than steady state")
	_check(saw_recovery_gain, "recovery phase restores stamina")
	_check(min_stamina < 1.0, "burst consumes stamina")
	_check(str(previous_state) in ["steady", "burst", "recovery"], "participant reports a valid struggle state")

	var high := _make_participant(_make_pending("catch-low-stamina", "herring", 0.3), profile, 101, Vector3(1.0, 0.0, 0.0))
	var low := _make_participant(_make_pending("catch-low-stamina", "herring", 0.3), profile, 101, Vector3(1.0, 0.0, 0.0))
	high.set("_struggle_state", PARTICIPANT_SCRIPT.StruggleState.BURST)
	high.set("_phase_remaining_s", 1.0)
	high.set("_current_pull_n", 0.0)
	low.set("_struggle_state", PARTICIPANT_SCRIPT.StruggleState.BURST)
	low.set("_phase_remaining_s", 1.0)
	low.set("_stamina_ratio", 0.16)
	low.set("_current_pull_n", 0.0)
	high.advance(0.15, Vector3(1.0, 0.0, 0.0))
	low.advance(0.15, Vector3(1.0, 0.0, 0.0))
	_check(float(low.get_read_only_snapshot().get("current_pull_n", INF)) < float(high.get_read_only_snapshot().get("current_pull_n", 0.0)), "low stamina reduces burst force")

	var zero_length := _make_participant(_make_pending("catch-zero-length", "herring", 0.0), profile, 5)
	_check(is_equal_approx(float(zero_length.get_read_only_snapshot().get("size_factor", 0.0)), 1.0), "zero body length uses reference-size force without rerolling identity")


func _test_large_dt_and_frame_partitioning() -> void:
	var profile := PROFILE_CATALOG.load_profile("needlefish")
	var pending := _make_pending("catch-partition", "needlefish", 0.63)
	var one_step := _make_participant(pending, profile, 742, Vector3(0.0, 0.0, 1.0))
	var many_steps := _make_participant(pending, profile, 742, Vector3(0.0, 0.0, 1.0))
	var thirty_fps := _make_participant(pending, profile, 742, Vector3(0.0, 0.0, 1.0))
	var sixty_fps := _make_participant(pending, profile, 742, Vector3(0.0, 0.0, 1.0))
	one_step.advance(12.0, Vector3(0.0, 0.0, 1.0))
	for _index in range(240):
		many_steps.advance(0.05, Vector3(0.0, 0.0, 1.0))
	for _index in range(360):
		thirty_fps.advance(1.0 / 30.0, Vector3(0.0, 0.0, 1.0))
	for _index in range(720):
		sixty_fps.advance(1.0 / 60.0, Vector3(0.0, 0.0, 1.0))
	_check(_snapshots_match(one_step.get_read_only_snapshot(), many_steps.get_read_only_snapshot(), 0.0002), "same 12 real seconds behave consistently as one step or 240 smaller steps")
	_check(_snapshots_match(thirty_fps.get_read_only_snapshot(), sixty_fps.get_read_only_snapshot(), 0.02), "30 and 60 update rates produce near-identical struggle outputs over the same real time")
	var large_step := _make_participant(pending, profile, 743, Vector3(0.0, 0.0, 1.0))
	var result: Dictionary = large_step.advance(90.0, Vector3(0.0, 0.0, 1.0))
	_check(is_finite(float(result.get("current_pull_n", NAN))) and is_finite(float(result.get("stamina_ratio", NAN))), "large dt is fully advanced without non-finite output")
	_check(float(result.get("phase_remaining_s", 0.0)) > 0.0 and float(result.get("phase_remaining_s", INF)) < profile.burst_interval_max_s, "large dt advances through phase boundaries instead of being discarded")


func _test_five_independent_participants() -> void:
	var profile := PROFILE_CATALOG.load_profile("herring")
	var participants: Array[BoatFishingFightParticipant] = []
	for index in range(5):
		participants.append(_make_participant(_make_pending("sabiki-catch-%d" % index, "herring", 0.2 + float(index) * 0.04, index), profile, -1, Vector3(0.0, 0.0, 1.0)))
	var first_burst_times: Dictionary = {}
	var saw_five_finite_outputs := true
	for time_index in range(1200):
		for fish_index in range(participants.size()):
			var participant := participants[fish_index]
			var before: Dictionary = participant.get_read_only_snapshot()
			if str(before.get("struggle_state", "")) != "burst" and not first_burst_times.has(fish_index):
				var next_snapshot: Dictionary = participant.advance(0.025, Vector3(0.0, 0.0, 1.0))
				if str(next_snapshot.get("struggle_state", "")) == "burst":
					first_burst_times[fish_index] = float(time_index + 1) * 0.025
			else:
				participant.advance(0.025, Vector3(0.0, 0.0, 1.0))
			var after: Dictionary = participant.get_read_only_snapshot()
			saw_five_finite_outputs = saw_five_finite_outputs and is_finite(float(after.get("current_pull_n", NAN))) and is_finite(float(after.get("stamina_ratio", NAN)))
	_check(participants.size() == 5 and saw_five_finite_outputs, "five hooked-fish participants update independently with finite outputs")
	_check(first_burst_times.size() == 5, "all five participants reach their own burst phase")
	var burst_times: Array = first_burst_times.values()
	burst_times.sort()
	var distinct_burst_times := 0
	var previous_time := -1.0
	for burst_time_variant in burst_times:
		var burst_time := float(burst_time_variant)
		if previous_time < 0.0 or absf(burst_time - previous_time) > 0.0001:
			distinct_burst_times += 1
		previous_time = burst_time
	_check(distinct_burst_times > 1, "five catch IDs do not synchronize their first struggle burst")


func _test_direction_constraints_and_independence() -> void:
	var profile := PROFILE_CATALOG.load_profile("sea_trout")
	var pending_a := _make_pending("catch-direction-a", "sea_trout", 0.55)
	var pending_b := _make_pending("catch-direction-b", "sea_trout", 0.55)
	var participant_a := _make_participant(pending_a, profile, 321, Vector3(1.0, 0.0, 0.0))
	var participant_b := _make_participant(pending_b, profile, 654, Vector3(1.0, 0.0, 0.0))
	var direction_a: Vector3 = participant_a.get_read_only_snapshot().get("swim_direction", Vector3.ZERO)
	_check(direction_a.length_squared() > 0.99 and direction_a.length_squared() < 1.01, "active swim intent is normalized")
	_check(direction_a.dot(Vector3.RIGHT) >= -0.000001, "active horizontal swim intent has no inward component")
	_check(absf(direction_a.z) > 0.0001 or absf(direction_a.y) > 0.0001, "active swim intent can include lateral or vertical movement")
	participant_a.advance(0.01, Vector3.LEFT)
	var turned_direction: Vector3 = participant_a.get_read_only_snapshot().get("swim_direction", Vector3.ZERO)
	_check(turned_direction.dot(Vector3.LEFT) >= -0.000001, "updated hull-relative reference prevents a turn from making intent point inward")
	var before_b: Dictionary = participant_b.get_read_only_snapshot()
	participant_a.advance(0.3, Vector3(1.0, 0.0, 0.0))
	_check(_snapshots_match(before_b, participant_b.get_read_only_snapshot()), "advancing one fish does not change another participant")
	var no_reference := _make_participant(_make_pending("catch-no-outward", "sea_trout", 0.55), profile, 10)
	var fallback: Dictionary = no_reference.get_read_only_snapshot()
	var fallback_direction: Vector3 = fallback.get("swim_direction", Vector3.ZERO)
	_check(not bool(fallback.get("direction_reference_valid", true)) and fallback_direction.is_finite(), "invalid outward reference uses a finite safe fallback")
	_check(fallback_direction.length_squared() > 0.99, "fallback direction remains normalized")


func _make_pending(catch_id: String, species_id: String, body_length_m: float, hook_index: int = -1, debug_spawned: bool = false) -> FishingPendingCatch:
	var pending := PENDING_CATCH_SCRIPT.new() as FishingPendingCatch
	pending.catch_id = catch_id
	pending.species_id = species_id
	pending.fishing_method = "boat_fishing"
	pending.school_id = "school-%s" % species_id
	pending.rig_id = "sabiki" if hook_index >= 0 else "single_jig"
	pending.hook_index = hook_index
	pending.debug_spawned = debug_spawned
	pending.hook_confirmed = true
	pending.body_length_m = body_length_m
	return pending


func _make_participant(
	pending: FishingPendingCatch,
	profile: BoatFishingFightProfile,
	seed: int = -1,
	outward: Vector3 = Vector3.ZERO
) -> BoatFishingFightParticipant:
	var participant := PARTICIPANT_SCRIPT.new() as BoatFishingFightParticipant
	_check(participant.initialize_from_pending_catch(pending, profile, seed, outward), "participant initializes from pending catch")
	return participant


func _snapshots_match(a: Dictionary, b: Dictionary, tolerance: float = 0.00001) -> bool:
	for key in ["catch_id", "hook_index", "species_id", "school_id", "rig_id", "debug_spawned", "fight_seed", "struggle_state", "struggle_state_id", "direction_reference_valid"]:
		if a.get(key) != b.get(key):
			return false
	for key in ["body_length_m", "size_factor", "stamina_ratio", "phase_remaining_s", "current_pull_n", "swim_speed_mps"]:
		if absf(float(a.get(key, 0.0)) - float(b.get(key, 0.0))) > tolerance:
			return false
	var a_direction: Vector3 = a.get("swim_direction", Vector3.ZERO)
	var b_direction: Vector3 = b.get("swim_direction", Vector3.ZERO)
	return a_direction.distance_to(b_direction) <= tolerance


func _check(condition: bool, message: String) -> void:
	if condition:
		print("[P6.4.2][PASS] %s" % message)
	else:
		_failures += 1
		push_error("[P6.4.2][FAIL] %s" % message)
