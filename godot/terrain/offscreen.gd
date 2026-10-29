## The test drivers' window kept out of the way (tests/offscreen.sh): with `--offscreen` among the user args
## the main window is made unfocusable and moved past the screen's bottom-right corner just after it is shown
## (macOS keeps a strip of it on the screen; set before the show, at _ready, the state is lost). Not minimized:
## Godot draws nothing while its only window is minimized, so GPU readbacks never land and the collider never
## goes live. The window keeps drawing off the screen's edge at the full frame rate, readbacks landing the
## next frame. Godot activates itself at launch whatever `open` is told; the script hands the focus back.
class_name Offscreen

## Seconds after _ready the window is moved: past its first show.
const DELAY := 0.1
## Where the window is sent; macOS clamps it to the screen's bottom-right corner.
const FAR := Vector2i(20000, 20000)


## Arranges the offscreen window state when asked for; whether it was.
static func apply() -> bool:
	if not OS.get_cmdline_user_args().has("--offscreen"):
		return false
	var tree := Engine.get_main_loop() as SceneTree
	tree.create_timer(DELAY).timeout.connect(func() -> void:
		DisplayServer.window_set_flag(DisplayServer.WINDOW_FLAG_NO_FOCUS, true)
		DisplayServer.window_set_position(FAR))
	return true
