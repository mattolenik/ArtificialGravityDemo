## The last GPU times of the detail pass and the collider bake, from the capture_timestamp pairs
## TerrainWindow and ColliderPatch put around their compute lists (pairs in one frame add up), and of the
## frame; refreshed every 30 frames. A backend that reports no GPU time (Metal returns zeros) shows
## "n/a" there, and the CPU time Performance.TIME_PROCESS reports (the slowest frame of the last second).
extends Label

## Last nonzero GPU time per pass in ms.
var _gpu := {"detail": 0.0, "bake": 0.0}
var _frames := 0


func _ready() -> void:
	RenderingServer.viewport_set_measure_render_time(get_viewport().get_viewport_rid(), true)


func _process(_delta: float) -> void:
	# Every frame, so a pass is seen in the one frame it ran; the text changes every 30.
	var rd := RenderingServer.get_rendering_device()
	var begin := {}
	var sum := {}
	for i in rd.get_captured_timestamps_count():
		var name := rd.get_captured_timestamp_name(i)
		var t := rd.get_captured_timestamp_gpu_time(i)
		if name.ends_with("_begin"):
			begin[name.trim_suffix("_begin")] = t
		elif name.ends_with("_end") and begin.has(name.trim_suffix("_end")):
			var pass_name := name.trim_suffix("_end")
			sum[pass_name] = sum.get(pass_name, 0) + t - begin[pass_name]
	for pass_name: String in _gpu:
		if sum.get(pass_name, 0) > 0:
			_gpu[pass_name] = sum[pass_name] / 1000.0
	_frames += 1
	if _frames % 30 != 0:
		return
	var times: Dictionary = _gpu.duplicate()
	times["frame"] = RenderingServer.viewport_get_measured_render_time_gpu(get_viewport().get_viewport_rid())
	var s := "GPU"
	for pass_name: String in times:
		s += "  %s %s" % [pass_name, "%.2f ms" % times[pass_name] if times[pass_name] > 0.0 else "n/a"]
	if times["frame"] <= 0.0:
		s += "   CPU %.2f ms" % (Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0)
	text = s
