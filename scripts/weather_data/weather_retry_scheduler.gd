extends RefCounted
class_name WeatherRetryScheduler

## Timing adapter for non-blocking retry backoff. Only the HTTP adapter's
## owning node is needed; the provider itself remains independent of SceneTree.

var owner_node: Node


func _init(node: Node = null) -> void:
	owner_node = node


func schedule(delay_seconds: float, callback: Callable) -> void:
	if not is_instance_valid(owner_node) or owner_node.get_tree() == null:
		callback.call()
		return
	var timer := owner_node.get_tree().create_timer(maxf(delay_seconds, 0.0))
	timer.timeout.connect(callback, CONNECT_ONE_SHOT)
