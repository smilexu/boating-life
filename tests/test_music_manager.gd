extends SceneTree

const MusicManagerScript := preload("res://scripts/music_manager.gd")
const GameMenuScript := preload("res://scripts/game_menu.gd")
const BoatControllerScript := preload("res://scripts/boat_controller.gd")

var _checks := 0
var _failures: Array[String] = []
var _settings_path := ""


class FakeCameraRig extends Node3D:
	var release_count := 0

	func release_mouse_look() -> void:
		release_count += 1


class FakeFishMap extends Node:
	var opened := false

	func is_map_open() -> bool:
		return opened


class FakePortServices extends Node:
	var opened := false

	func is_menu_open() -> bool:
		return opened


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var time_manager := root.get_node_or_null("WorldTimeManager")
	if time_manager != null:
		time_manager.set("autosave_enabled", false)
	var production_manager := root.get_node_or_null("MusicManager")
	if production_manager != null:
		production_manager.set("music_enabled", false)
		production_manager.call("_cancel_fade")
		var production_player := production_manager.get_node_or_null("BackgroundMusicPlayer") as AudioStreamPlayer
		if production_player != null:
			production_player.stop()
			production_player.stream = null

	_settings_path = "/private/tmp/m2_music_manager_test_%d.cfg" % OS.get_process_id()
	DirAccess.remove_absolute(_settings_path)
	var holder := Node.new()
	holder.name = "MusicMenuTestHolder"
	root.add_child(holder)
	var manager := _make_manager("MusicManagerTest", true)
	holder.add_child(manager)
	await process_frame
	await process_frame
	var player := manager.get_node("BackgroundMusicPlayer") as AudioStreamPlayer
	_expect(manager.is_music_enabled(), "missing setting defaults to music enabled")
	_expect(manager.get_current_track_name() == "bgm1" and player.playing, "startup begins with bgm1")
	_expect(player.bus == "Music" and AudioServer.get_bus_index("Music") >= 0, "background player uses its own Music bus")
	_expect(AudioServer.get_bus_send(AudioServer.get_bus_index("Music")) == "Master", "Music bus sends to Master")
	_expect(manager.get("_fade_tween") != null, "startup fades music in")

	manager._on_track_finished()
	_expect(manager.get_current_track_name() == "bgm2" and player.playing, "finished signal advances from bgm1 to bgm2")
	manager._on_track_finished()
	_expect(manager.get_current_track_name() == "bgm1" and player.playing, "finished signal wraps from bgm2 to bgm1")
	manager.set_music_enabled(false)
	_expect(player.playing, "music remains active during the fade-out interval")
	manager.set_music_enabled(true)
	_expect(player.playing, "re-enabling during fade-out reuses the same player")
	manager.set_music_enabled(false)
	await create_timer(1.4).timeout
	_expect(not player.playing, "fade-out eventually stops the player")
	var resume_position := float(manager.get("_saved_position_seconds"))
	_expect(resume_position > 0.5, "fade-out preserves the current playback position")
	manager.set_music_enabled(true)
	_expect(player.playing and float(manager.get("_saved_position_seconds")) > 0.5, "re-enabling resumes within the same track")
	manager.set_music_enabled(false)
	await create_timer(1.4).timeout
	var saved_config := ConfigFile.new()
	_expect(saved_config.load(_settings_path) == OK and not bool(saved_config.get_value("audio", "music_enabled", true)), "off preference is saved immediately")

	manager.queue_free()
	await process_frame
	var restored_manager := _make_manager("MusicManagerRestored", true)
	holder.add_child(restored_manager)
	await process_frame
	await process_frame
	var restored_player := restored_manager.get_node("BackgroundMusicPlayer") as AudioStreamPlayer
	_expect(not restored_manager.is_music_enabled() and not restored_player.playing, "saved disabled setting restores without playback")
	restored_manager.set_music_enabled(true)
	_expect(restored_player.playing and restored_manager.get_current_track_name() == "bgm1", "enabling resumes the current track")
	_expect(restored_manager.get("_fade_tween") != null, "enabling starts a fade-in")
	restored_manager.set_music_enabled(false)
	restored_manager.set_music_enabled(true)
	_expect(restored_player.playing, "rapid repeated toggles do not stop or duplicate playback")
	var enabled_restart := _make_manager("MusicManagerEnabledRestartTest", true)
	holder.add_child(enabled_restart)
	await process_frame
	await process_frame
	var enabled_restart_player := enabled_restart.get_node("BackgroundMusicPlayer") as AudioStreamPlayer
	_expect(enabled_restart.is_music_enabled() and enabled_restart_player.playing, "saved enabled setting starts music after restart")
	enabled_restart.queue_free()
	await process_frame
	var player_count := 0
	for child in restored_manager.get_children():
		if child is AudioStreamPlayer:
			player_count += 1
	_expect(player_count == 1, "MusicManager owns exactly one AudioStreamPlayer")

	await _test_missing_track_is_skipped(holder)
	await _test_corrupt_settings_fallback(holder)
	await _test_menu_input_and_navigation(holder, restored_manager)

	restored_manager.queue_free()
	holder.queue_free()
	await process_frame
	DirAccess.remove_absolute(_settings_path)
	if is_instance_valid(production_manager):
		production_manager.queue_free()
		await process_frame
	_expect(_failures.is_empty(), "all music/menu assertions pass")
	if _failures.is_empty():
		print("MusicManager and GameMenu tests: %d checks passed." % _checks)
		quit(0)
	else:
		for failure in _failures:
			push_error(failure)
		quit(1)


func _make_manager(node_name: String, auto_start: bool) -> Node:
	var manager := MusicManagerScript.new() as Node
	manager.name = node_name
	manager.set("settings_file_path", _settings_path)
	manager.set("start_playback_on_ready", auto_start)
	return manager


func _test_missing_track_is_skipped(holder: Node) -> void:
	var missing_settings_path := "/private/tmp/m2_music_manager_missing_test_%d.cfg" % OS.get_process_id()
	var manager := _make_manager("MusicManagerMissingTrackTest", false)
	manager.set("settings_file_path", missing_settings_path)
	var definitions: Array[Dictionary] = [
		{"id": "missing", "ogg_path": "res://tests/missing_track.ogg", "mp3_fallback_path": ""},
		{"id": "fallback", "ogg_path": "res://tests/missing_fallback.ogg", "mp3_fallback_path": "res://assets/music/bgm2.mp3"},
	]
	manager.set("track_definitions", definitions)
	holder.add_child(manager)
	await process_frame
	manager.call("set_music_enabled", true)
	var player := manager.get_node("BackgroundMusicPlayer") as AudioStreamPlayer
	_expect(str(manager.call("get_current_track_name")) == "fallback" and player.playing, "missing OGG is reported and the MP3 fallback is played")
	player.stop()
	manager.queue_free()
	await process_frame
	var main_scene := ResourceLoader.load("res://scenes/main.tscn") as PackedScene
	_expect(main_scene != null, "main scene resource loads with the new menu node")
	if main_scene != null:
		var main_instance := main_scene.instantiate()
		_expect(main_instance.get_node_or_null("GameMenu") != null, "main scene contains exactly one GameMenu node")
		var fish_map_node := main_instance.get_node_or_null("FishResourceMap")
		_expect(fish_map_node != null and fish_map_node.get("manager_path") == NodePath("../FishResourceManager"), "FishResourceMap paths remain assigned to the map node")
		main_instance.free()
	DirAccess.remove_absolute(missing_settings_path)


func _test_corrupt_settings_fallback(holder: Node) -> void:
	var corrupt_settings_path := "/private/tmp/m2_music_manager_corrupt_test_%d.cfg" % OS.get_process_id()
	var file := FileAccess.open(corrupt_settings_path, FileAccess.WRITE)
	file.store_string("[audio\nmusic_enabled=not-a-boolean\n")
	file.close()
	var manager := _make_manager("MusicManagerCorruptSettingsTest", false)
	manager.set("settings_file_path", corrupt_settings_path)
	holder.add_child(manager)
	await process_frame
	_expect(bool(manager.call("is_music_enabled")), "corrupt settings fall back to the default enabled value")
	manager.queue_free()
	await process_frame
	DirAccess.remove_absolute(corrupt_settings_path)


func _test_menu_input_and_navigation(holder: Node, manager: Node) -> void:
	var boat := BoatControllerScript.new() as BoatController
	boat.name = "Boat"
	holder.add_child(boat)
	var camera_rig := FakeCameraRig.new()
	camera_rig.name = "CameraRig"
	holder.add_child(camera_rig)
	var fish_map := FakeFishMap.new()
	fish_map.name = "FishMap"
	holder.add_child(fish_map)
	var port_services := FakePortServices.new()
	port_services.name = "PortServices"
	holder.add_child(port_services)
	var menu := GameMenuScript.new() as CanvasLayer
	menu.name = "GameMenuTest"
	menu.set("boat_controller_path", NodePath("../Boat"))
	menu.set("camera_rig_path", NodePath("../CameraRig"))
	menu.set("music_manager_path", NodePath("../MusicManagerRestored"))
	menu.set("fish_map_path", NodePath("../FishMap"))
	menu.set("malmo_port_services_path", NodePath("../PortServices"))
	menu.set("copenhagen_port_services_path", NodePath("../MissingPortServices"))
	holder.add_child(menu)
	await process_frame

	var escape := InputEventKey.new()
	escape.pressed = true
	escape.keycode = KEY_ESCAPE
	escape.physical_keycode = KEY_ESCAPE
	menu.call("_unhandled_key_input", escape)
	_expect(bool(menu.call("is_menu_open")) and not boat.manual_input_enabled, "ESC opens menu and blocks manual vessel input")
	_expect(camera_rig.release_count == 1, "opening menu releases captured camera look")
	Input.action_press("boat_accelerate")
	boat._process(1.0)
	Input.action_release("boat_accelerate")
	_expect(is_zero_approx(boat.speed_mps) and is_zero_approx(boat.rotation.y), "manual boat controls stay inactive while the menu is open")
	_expect(not paused, "opening the menu does not pause world time or simulation")
	boat.submit_autopilot_command(0.25, 5.0)
	boat._process(0.5)
	_expect(boat.is_autopilot and boat.speed_mps > 0.0, "autopilot continues to advance while the menu is open")
	menu.call("_show_settings_page")
	_expect(bool(menu.call("is_settings_open")), "Settings page opens from the main menu")
	var music_toggle := menu.find_child("MusicEnabledToggle", true, false) as CheckButton
	_expect(music_toggle.button_pressed, "Settings reflects the current enabled music state")
	menu.call("_unhandled_key_input", escape)
	_expect(bool(menu.call("is_menu_open")) and not bool(menu.call("is_settings_open")), "ESC in Settings returns to the main menu")
	menu.call("_unhandled_key_input", escape)
	_expect(not bool(menu.call("is_menu_open")) and boat.manual_input_enabled, "ESC closes the main menu and restores manual input")
	_expect(boat.is_autopilot, "menu open/close does not cancel autopilot")

	fish_map.opened = true
	menu.call("_unhandled_key_input", escape)
	_expect(not bool(menu.call("is_menu_open")), "ESC is left to the existing fish map overlay")
	fish_map.opened = false
	port_services.opened = true
	menu.call("_unhandled_key_input", escape)
	_expect(not bool(menu.call("is_menu_open")), "ESC is left to the existing port services menu")
	port_services.opened = false

	menu.call("_open_menu")
	menu.call("_show_settings_page")
	music_toggle.set_pressed_no_signal(false)
	music_toggle.toggled.emit(false)
	_expect(not bool(manager.call("is_music_enabled")), "settings toggle updates MusicManager")
	_expect(manager.get("_fade_tween") != null, "settings toggle starts the music fade-out")
	menu.call("_unhandled_key_input", escape)
	menu.call("_close_menu")
	menu.queue_free()
	boat.queue_free()
	camera_rig.queue_free()
	fish_map.queue_free()
	port_services.queue_free()
	await process_frame


func _expect(condition: bool, description: String) -> void:
	_checks += 1
	if not condition:
		_failures.append(description)
		push_error("Music/menu test failed: " + description)
