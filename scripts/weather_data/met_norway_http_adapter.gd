extends Node
class_name MetNorwayHttpAdapter

## Asynchronous HTTP transport. It accepts already prepared headers and does
## not know about game weather state or region selection.


func request(request_data: Dictionary, callback: Callable) -> void:
	var http := HTTPRequest.new()
	http.name = "WeatherHttpRequest_%d" % get_instance_id()
	http.use_threads = true
	http.timeout = maxf(float(request_data.get("timeout_seconds", 20.0)), 1.0)
	http.accept_gzip = true
	http.max_redirects = 5
	add_child(http)
	http.request_completed.connect(_on_request_completed.bind(http, callback), CONNECT_ONE_SHOT)
	var request_error := http.request(
		str(request_data.get("url", "")),
		PackedStringArray(request_data.get("headers", [])),
		HTTPClient.METHOD_GET
	)
	if request_error != OK:
		callback.call({
			"transport_result": HTTPRequest.RESULT_CANT_CONNECT,
			"status_code": 0,
			"headers": PackedStringArray(),
			"body": PackedByteArray(),
			"request_error": request_error,
		})
		http.queue_free()


func _on_request_completed(
	result: int,
	status_code: int,
	headers: PackedStringArray,
	body: PackedByteArray,
	http: HTTPRequest,
	callback: Callable
) -> void:
	callback.call({
		"transport_result": result,
		"status_code": status_code,
		"headers": headers,
		"body": body,
	})
	http.queue_free()
