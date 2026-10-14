extends CanvasLayer

## Test-only overlay for checking compositor cost and toggling the cloud pass.

@export_node_path("SunshineCloudsDriverGD") var driver_path := NodePath("../SunshineCloudsDriverGD")

var _driver: SunshineCloudsDriverGD
var _status_label: Label


func _ready() -> void:
	_driver = get_node_or_null(driver_path) as SunshineCloudsDriverGD
	var panel := PanelContainer.new()
	panel.position = Vector2(24.0, 24.0)
	panel.custom_minimum_size = Vector2(410.0, 74.0)
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.035, 0.12, 0.16, 0.82)
	style.set_corner_radius_all(8)
	style.content_margin_left = 14.0
	style.content_margin_right = 14.0
	style.content_margin_top = 10.0
	style.content_margin_bottom = 10.0
	panel.add_theme_stylebox_override("panel", style)
	_status_label = Label.new()
	_status_label.add_theme_font_size_override("font_size", 17)
	_status_label.add_theme_color_override("font_color", Color(0.92, 0.96, 0.96))
	panel.add_child(_status_label)
	add_child(panel)
	_update_status()


func _process(_delta: float) -> void:
	_update_status()


func _unhandled_key_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo and event.physical_keycode == KEY_F2:
		if _driver != null and _driver.clouds_resource != null:
			_driver.clouds_resource.enabled = not _driver.clouds_resource.enabled
		_update_status()
		get_viewport().set_input_as_handled()


func _update_status() -> void:
	if _status_label == null:
		return
	var clouds_enabled := false
	if _driver != null and _driver.clouds_resource != null:
		clouds_enabled = _driver.clouds_resource.enabled
	_status_label.text = "Sunshine Clouds 2: %s  ·  F2 开关  ·  F1 快速转镜头\nFPS: %d  ·  1920×1080" % [
		"ON" if clouds_enabled else "OFF",
		Engine.get_frames_per_second(),
	]
