## The last GPU times of the detail pass, the collider bakes (big and edit) and the edit layer's stamp (with
## its pack), apply and tile packs, and of the simulation's steps, from the capture_timestamp pairs
## TerrainWindow, ColliderPatch, EditLayer and TerrainSim put around their compute lists (pairs in one frame
## add up), and of the frame; refreshed every 30 frames. A backend that reports no GPU time (Metal returns
## zeros) shows "n/a" there, and the CPU time Performance.TIME_PROCESS reports (the slowest frame of the last
## second).
extends Label

## One compute list's GPU time in ms, for each begin/end pair that has a time. Each captured frame is
## read once, so a pair is announced once.
signal timed(pass_name: String, ms: float)

## Last nonzero GPU time per pass in ms.
var _gpu := {"detail": 0.0, "bake": 0.0, "bake_edit": 0.0, "edit": 0.0, "apply": 0.0, "pack": 0.0, "sim": 0.0}
var _frames := 0
var _stamp_frame := -1


func _ready() -> void:
	RenderingServer.viewport_set_measure_render_time(get_viewport().get_viewport_rid(), true)


func _process(_delta: float) -> void:
	# Every frame, so a pass is seen in the one frame it ran; the text changes every 30.
	var rd := RenderingServer.get_rendering_device()
	if rd.get_captured_timestamps_frame() != _stamp_frame:
		_stamp_frame = rd.get_captured_timestamps_frame()
		_read_stamps(rd)
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


func _read_stamps(rd: RenderingDevice) -> void:
	var begin := {}
	var sum := {}
	for i in rd.get_captured_timestamps_count():
		var stamp := rd.get_captured_timestamp_name(i)
		var t := rd.get_captured_timestamp_gpu_time(i)
		if stamp.ends_with("_begin"):
			begin[stamp.trim_suffix("_begin")] = t
		elif stamp.ends_with("_end") and begin.has(stamp.trim_suffix("_end")):
			var pass_name := stamp.trim_suffix("_end")
			sum[pass_name] = sum.get(pass_name, 0) + t - begin[pass_name]
			if t > begin[pass_name]:
				timed.emit(pass_name, (t - begin[pass_name]) / 1.0e6)  # ns
	for pass_name: String in _gpu:
		if sum.get(pass_name, 0) > 0:
			_gpu[pass_name] = sum[pass_name] / 1.0e6
