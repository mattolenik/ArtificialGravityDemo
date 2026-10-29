## Debug key P: reads a TerrainWindow's fields back from the GPU and saves
## user://debug/window_surface.png (heights scaled min..max to grey) and window_material.png (dirt,
## clay, rock in their tile colours, rock face in a debug red, half dark brown under loose dirt, half blue
## under water), unrolled so the window's first tile is top-left (x along theta, y along z), and prints the
## height range, cell counts, the loose and sheet water cells, maxima and volumes (each cell's true area
## (R - s) dtheta cell²) and the material rule: every rock face cell has bedrock_top at the surface (1e-3)
## and every rock cell at or above it less 0.01. Synchronous readback: a debug key only.
extends Node

var window: TerrainWindow
## The tile the window was last moved to, for unrolling the toroidal layout.
var center: Vector2i
## The last dump's loose volume, m³ (for tool_run's check).
var loose_volume := 0.0

## The rock face is drawn red here (the tiles colour it as rock) so the image tells it from an outcrop.
const COLOURS := [Color(0.45, 0.33, 0.2), Color(0.6, 0.55, 0.45), Color(0.5, 0.5, 0.52), Color(0.8, 0.25, 0.2)]


func _unhandled_key_input(event: InputEvent) -> void:
	var key := event as InputEventKey
	if key and key.pressed and not key.echo and key.keycode == KEY_P:
		RenderingServer.call_on_render_thread(_dump)


func _dump() -> void:
	var rd := RenderingServer.get_rendering_device()
	var n := window.size
	var o := window.texel_origin(window.wanted_tiles(center)[0])
	var heights := rd.texture_get_data(window.texture_rid("surface"), 0).to_float32_array()
	var bedrock := rd.texture_get_data(window.texture_rid("bedrock_top"), 0).to_float32_array()
	var water := rd.texture_get_data(window.texture_rid("water_surface"), 0).to_float32_array()
	var loose := rd.texture_get_data(window.texture_rid("loose"), 0).to_float32_array()
	var sheet := rd.texture_get_data(window.texture_rid("water_depth"), 0).to_float32_array()
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
	var counts := [0, 0, 0, 0]
	var first := window.wanted_tiles(center)[0] * TerrainWindow.TILE
	var bad := ""
	var wet := 0
	# A cell's true area is (R - s) times this.
	var area_per_r := window.params.dtheta() * window.cell * window.cell
	var loose_cells := 0
	var loose_max := 0.0
	loose_volume = 0.0
	var sheet_cells := 0
	var sheet_max := 0.0
	var sheet_volume := 0.0
	for y in n:
		for x in n:
			var i := posmod(y + o.y, n) * n + posmod(x + o.x, n)
			var j := y * n + x
			grey[j] = int((heights[i] - lo) * k)
			var c: Color = COLOURS[ids[i]]
			if loose[i] > 0.0:
				c = c.lerp(Color(0.3, 0.2, 0.1), 0.5)
				loose_cells += 1
				loose_max = maxf(loose_max, loose[i])
				loose_volume += loose[i] * (window.params.radius - heights[i]) * area_per_r
			if sheet[i] > 0.0:
				sheet_cells += 1
				sheet_max = maxf(sheet_max, sheet[i])
				sheet_volume += sheet[i] * (window.params.radius - heights[i]) * area_per_r
			if water[i] > heights[i] + loose[i]:
				c = c.lerp(Color(0.2, 0.4, 0.9), 0.5)
				wet += 1
			rgb[3 * j] = c.r8
			rgb[3 * j + 1] = c.g8
			rgb[3 * j + 2] = c.b8
			counts[ids[i]] += 1
			if bad.is_empty() and ((ids[i] == MaterialSet.ROCK_FACE and absf(bedrock[i] - heights[i]) > 1e-3) \
					or (ids[i] == 2 and bedrock[i] < heights[i] - 0.01)):
				bad = "cell %s material %d surface %.4f bedrock_top %.4f" % [first + Vector2i(x, y), ids[i], heights[i], bedrock[i]]
	DirAccess.make_dir_recursive_absolute("user://debug")
	Image.create_from_data(n, n, false, Image.FORMAT_L8, grey).save_png("user://debug/window_surface.png")
	Image.create_from_data(n, n, false, Image.FORMAT_RGB8, rgb).save_png("user://debug/window_material.png")
	print("window surface min %.2f max %.2f m; dirt %d clay %d rock %d face %d cells; %d under water" % [lo, hi, counts[0], counts[1], counts[2], counts[3], wet])
	print("loose %d cells, max %.2f m, %.1f m3; sheet %d cells, max %.3f m, %.2f m3" % [loose_cells, loose_max, loose_volume,
			sheet_cells, sheet_max, sheet_volume])
	print("material rule: ", "ok" if bad.is_empty() else bad)
