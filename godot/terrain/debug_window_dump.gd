## Debug key P: reads a TerrainWindow's fields back from the GPU and saves
## user://debug/window_surface.png (heights scaled min..max to grey) and window_material.png (dirt,
## clay, rock in their tile colours, half blue under water), unrolled so the window's first tile is
## top-left (x along theta, y along z), and prints the height range and cell counts. Synchronous
## readback: a debug key only.
extends Node

var window: TerrainWindow
## The tile the window was last moved to, for unrolling the toroidal layout.
var center: Vector2i

const COLOURS := [Color(0.45, 0.33, 0.2), Color(0.6, 0.55, 0.45), Color(0.5, 0.5, 0.52)]


func _unhandled_key_input(event: InputEvent) -> void:
	var key := event as InputEventKey
	if key and key.pressed and not key.echo and key.keycode == KEY_P:
		RenderingServer.call_on_render_thread(_dump)


func _dump() -> void:
	var rd := RenderingServer.get_rendering_device()
	var n := window.size
	var o := window.texel_origin(window.wanted_tiles(center)[0])
	var heights := rd.texture_get_data(window.texture_rid("surface"), 0).to_float32_array()
	var water := rd.texture_get_data(window.texture_rid("water_surface"), 0).to_float32_array()
	var ids := rd.texture_get_data(window.texture_rid("material"), 0)
	var lo := INF
	var hi := -INF
	for h in heights:
		lo = minf(lo, h)
		hi = maxf(hi, h)
	var k := 255.0 / maxf(hi - lo, 1e-6)
	var grey := PackedByteArray()
	grey.resize(n * n)
	var rgb := PackedByteArray()
	rgb.resize(3 * n * n)
	var counts := [0, 0, 0]
	var wet := 0
	for y in n:
		for x in n:
			var i := posmod(y + o.y, n) * n + posmod(x + o.x, n)
			var j := y * n + x
			grey[j] = int((heights[i] - lo) * k)
			var c: Color = COLOURS[ids[i]]
			if water[i] > heights[i]:
				c = c.lerp(Color(0.2, 0.4, 0.9), 0.5)
				wet += 1
			rgb[3 * j] = c.r8
			rgb[3 * j + 1] = c.g8
			rgb[3 * j + 2] = c.b8
			counts[ids[i]] += 1
	DirAccess.make_dir_recursive_absolute("user://debug")
	Image.create_from_data(n, n, false, Image.FORMAT_L8, grey).save_png("user://debug/window_surface.png")
	Image.create_from_data(n, n, false, Image.FORMAT_RGB8, rgb).save_png("user://debug/window_material.png")
	print("window surface min %.2f max %.2f m; dirt %d clay %d rock %d cells; %d under water" % [lo, hi, counts[0], counts[1], counts[2], wet])
