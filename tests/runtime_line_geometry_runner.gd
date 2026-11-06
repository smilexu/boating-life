extends Node

## Editor F6 entry for the same production-scene runtime test used by --script.
func _ready() -> void:
	var tree := get_tree()
	tree.set_script(load("res://tests/test_p6_4_6_1_3_sabiki_single_line.gd"))
	tree.call_deferred("_run")
	queue_free()
