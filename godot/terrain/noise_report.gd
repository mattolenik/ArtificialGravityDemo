## Windowed noise report (the terrain noise-octaves plan). Instantiates main.tscn unchanged and, once the
## first collider patch is live, takes the fly camera and parks it at each site in turn: the spawn, the
## highest bare-rock macro cell (rock_site) and, with --at, a site of the user's choosing. At each it prints
## the collider mismatch over the live 257 m patch (row_mismatch at every drawn vertex), saves the window
## dump (key P) and an eye-height and a high view looking spinward under the light bar's noon, as
## user://debug/noise/<label>_<site>_{surface,material,eye,high}.png; then prints the detail timing line
## (GPU timestamps: Vulkan only, Metal reports zeros) and quits. One-shot readback loops: debug only.
## Run: godot --path . [--rendering-driver vulkan] res://terrain/noise_report.tscn -- [--label=NAME] [--at=THETA,Z]
class_name NoiseReport
extends Node

const OUT := "user://debug/noise/"
const Smoke := preload("res://terrain/smoke_run.gd")

var _label := "run"
var _at := PackedFloat64Array()
var _terrain: Terrain
var _fly: FlyCamera
var _light: LightBar
var _panel: CanvasLayer
var _dump := preload("res://terrain/debug_window_dump.gd").new()
var _started := false
## Detail list times in ms and tiles per detail dispatch, in order, from _route on.
var _detail: Array[float] = []
var _tiles: Array[int] = []


func _ready() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--label="):
			_label = arg.trim_prefix("--label=")
		elif arg.begins_with("--at="):
			_at = arg.trim_prefix("--at=").split_floats(",")
	var main: Node = load("res://main.tscn").instantiate()
	var station := main.get_node("Station")
	_terrain = station.get_node("Terrain")
	_fly = station.get_node("FlyCamera")
	_light = station.get_node("LightBar")
	_panel = main.get_node("Panel")
	main.get_node("Panel/Box/Timing").timed.connect(_on_timed)
	_terrain.collider_live.connect(_route, CONNECT_ONE_SHOT)
	add_child(_dump)
	add_child(main)
	for i in 1200:
		if _started:
			return
		await get_tree().process_frame
	push_error("The first collider patch did not go live in 1200 frames.")
	get_tree().quit(1)


## The route is scripted: a stray click must not capture the mouse, nor mouse movement turn the camera.
func _input(event: InputEvent) -> void:
	if event is InputEventMouse:
		get_viewport().set_input_as_handled()


func _route() -> void:
	_started = true
	# Windows exist now (Terrain._ready has run); from here on the detail lists are the window's moves.
	_terrain.window.tiles_generated.connect(_on_tiles)
	_terrain.far.window.tiles_generated.connect(_on_tiles)
	_fly.toggle()
	# The frozen player stands where the spawn's eye view is taken.
	_fly.player.visible = false
	_panel.visible = false
	_light.day_length = 1e9
	var maps := _terrain.maps
	await _visit("spawn", maps.spawn.x, maps.spawn.y)
	var rock := rock_site(maps, _terrain.params)
	await _visit("rock", rock.x, rock.y)
	if _at.size() == 2:
		await _visit("at", _at[0], _at[1])
	# Let the last timestamps arrive.
	for i in 6:
		await get_tree().process_frame
	print("detail lists: %s; tiles per dispatch %s..%s; %s" % [Smoke._stat(_detail, 2.0), _tiles.min() if _tiles else "-",
			_tiles.max() if _tiles else "-", Smoke._per_tile(_detail, _tiles)])
	get_tree().quit()


## Parks the camera 60 m over the site until the collider patch lies under it, prints the site line, and
## saves the window dump and the two views.
func _visit(site: String, theta: float, z: float) -> void:
	var R := _terrain.params.radius
	var ground := _terrain.height_at(theta, z)
	_light.theta = theta
	_place(Cyl.position(theta, z, ground + 60.0, R), theta, 0.0)
	var frames := 0
	# Terrain rebuilds the patch around the camera; it has landed once it no longer needs one there.
	while _terrain.patch.needs_rebuild(_fly.position) or frames < 3:
		await get_tree().process_frame
		frames += 1
		if frames > 600:
			push_error("No collider patch at %s after 600 frames." % site)
			get_tree().quit(1)
			return
	var m := _mismatch()
	print("site %s theta %.4f z %.1f: mismatch n %d skipped %d, |e| p99 %.1f cm max %.1f cm, mesh above collider up to %.1f cm below up to %.1f cm, surface md5 near %s far %s" % [
			site, theta, z, m.n, m.skipped, m.p99 * 100, m.max * 100, m.above * 100, m.below * 100, m.near, m.far])
	var base := OUT + _label + "_" + site
	DirAccess.make_dir_recursive_absolute(OUT)
	_dump.window = _terrain.window
	_dump.center = _terrain.window.center_tile
	RenderingServer.call_on_render_thread(_dump._dump)
	for f in ["surface", "material"]:
		var err := DirAccess.rename_absolute("user://debug/window_%s.png" % f, "%s_%s.png" % [base, f])
		if err != OK:
			push_error("moving the %s dump: %s" % [f, error_string(err)])
	var on := Cyl.position(theta, z, ground, R)
	for view: Array in [["eye", _terrain.patch.surface_point(on, 1.7), 10.0], ["high", Cyl.position(theta, z, ground + 120.0, R), 40.0]]:
		_place(view[1], theta, view[2])
		for i in 2:
			await get_tree().process_frame
		await RenderingServer.frame_post_draw
		get_viewport().get_texture().get_image().save_png("%s_%s.png" % [base, view[0]])


## Puts the fly camera at the station-space point `at`, looking spinward and tilted down by tilt_deg.
func _place(at: Vector3, theta: float, tilt_deg: float) -> void:
	var up := Vector3(-sin(theta), cos(theta), 0)
	var spinward := Vector3(cos(theta), sin(theta), 0)
	var tilt := deg_to_rad(tilt_deg)
	_fly.transform = Transform3D(Basis.looking_at(cos(tilt) * spinward - sin(tilt) * up, up), at)


## The mismatch over the live patch: every drawn vertex of the window within its 257 rows and +-128 m,
## against the collider (row_mismatch). n samples, `skipped` vertices dropped as outside the window or next
## to one, p99 and max of |e|, the most the mesh lies above and below the collider (m), and the first 8
## hex digits of the MD5 of the near and far windows' surface textures.
func _mismatch() -> Dictionary:
	var p := _terrain.params
	var w := _terrain.window
	var R := p.radius
	var dtheta := p.dtheta()
	var n_theta := p.n_theta()
	var bytes: Array[PackedByteArray] = []
	RenderingServer.call_on_render_thread(func() -> void:
		var rd := RenderingServer.get_rendering_device()
		bytes.append(rd.texture_get_data(w.texture_rid("surface"), 0))
		bytes.append(rd.texture_get_data(_terrain.far.window.texture_rid("surface"), 0)))
	var surface := bytes[0].to_float32_array()
	var center := _terrain.patch.center
	var c := Vector2i(posmod(floori(center.x / dtheta), n_theta), floori(center.y + p.length / 2.0))
	# As ColliderPatch._bake: enough samples to reach past x = 128 m at the highest ground.
	var half := ceili(asin(minf(129.0 / (R - p.h_sea - p.h_mtn()), 1.0)) / dtheta)
	var wanted := {}
	for t in w.wanted_tiles(w.center_tile):
		wanted[t] = true
	var map: PackedFloat32Array = _terrain.patch.get_node("CollisionShape3D").shape.map_data
	var e := PackedFloat32Array()
	var skipped := 0
	var h := PackedFloat32Array()
	h.resize(2 * half + 1)
	for j in ColliderPatch.SAMPLES:
		var row := c.y + j - 128
		if row < 0 or row >= p.n_z():
			continue
		var outside := false
		for k in h.size():
			var i := posmod(c.x + k - half, n_theta)
			if wanted.has(w.tile_of_cell(i, row)):
				# The shader's slot addressing: size = slots * TILE.
				h[k] = surface[posmod(row, w.size) * w.size + posmod(i, w.size)]
			else:
				h[k] = NAN
				outside = true
		var collider := map.slice(j * ColliderPatch.SAMPLES, (j + 1) * ColliderPatch.SAMPLES)
		var got := row_mismatch(h, dtheta, R, collider)
		e.append_array(got)
		if outside:
			# What the bake read there instead (the macro surface) tells how many vertices were dropped.
			for k in h.size():
				if is_nan(h[k]):
					h[k] = _terrain.height_at((posmod(c.x + k - half, n_theta) + 0.5) * dtheta, -p.length / 2.0 + row + 0.5)
			skipped += row_mismatch(h, dtheta, R, collider).size() - got.size()
	var mags := e.duplicate()
	var above := 0.0
	var below := 0.0
	for i in e.size():
		mags[i] = absf(e[i])
		above = maxf(above, e[i])
		below = maxf(below, -e[i])
	mags.sort()
	return {"n": e.size(), "skipped": skipped, "p99": mags[int(0.99 * e.size())], "max": mags[-1], "above": above,
			"below": below, "near": _md5(bytes[0]), "far": _md5(bytes[1])}


## y - collider at every drawn vertex of one row: h[k] is the drawn height at angle
## (k - (h.size() - 1) / 2) * dtheta from the patch centre, mapped to (x, y) = ((R - h) sin phi,
## h + 2 (R - h) sin^2(phi / 2)) as Cyl.bake_row and collider_bake.glsl do; row is one collider row of 257
## samples, sample i at x = i - 128, read linearly between the two around x. Vertices with |x| > 128 are
## left out, as are NaN heights (outside the window, where the bake read the macro surface) and every
## vertex whose two collider samples do not both lie on its run of drawn heights: toward a NaN the bake's
## chord runs to a macro sample. With cells of 1 m or more that is the NaN's two neighbours; narrower cells
## can add one more on a side.
static func row_mismatch(h: PackedFloat32Array, dtheta: float, R: float, row: PackedFloat32Array) -> PackedFloat32Array:
	var n := h.size()
	var x := PackedFloat64Array()
	x.resize(n)
	for k in n:
		x[k] = (R - h[k]) * sin((k - (n - 1) / 2.0) * dtheta)
	var out := PackedFloat32Array()
	var a := 0
	while a < n:
		if is_nan(h[a]):
			a += 1
			continue
		# The run a..b of drawn heights; its x span bounds the collider samples a vertex may use where it ends
		# at a NaN.
		var b := a
		while b + 1 < n and not is_nan(h[b + 1]):
			b += 1
		var lo := x[a] if a > 0 else -INF
		var hi := x[b] if b < n - 1 else INF
		for k in range(a, b + 1):
			var i := mini(floori(x[k]) + 128, 255)
			if absf(x[k]) > 128.0 or i - 128 < lo or i - 127 > hi:
				continue
			var phi := (k - (n - 1) / 2.0) * dtheta
			out.append(h[k] + 2.0 * (R - h[k]) * sin(phi / 2.0) ** 2 - lerpf(row[i], row[i + 1], x[k] + 128.0 - i))
		a = b + 1
	return out


## (theta, z) of the centre of the highest macro cell that is bare rock (bedrock_top within 1 m of the
## surface), or of the highest cell of all if none is; either way not a cliff rim (whose views face the
## cliff) and at least 5 cells from either station end (so the 257 m patch stays on the station).
static func rock_site(maps: MacroMaps, params: WorldParams) -> Vector2:
	var s := maps.surface.get_data().to_float32_array()
	var b := maps.bedrock_top.get_data().to_float32_array()
	var rim := maps.cliff.get_data()
	var w := maps.surface.get_width()
	var top := -1
	var bare := -1
	for y in range(5, maps.surface.get_height() - 5):
		for x in w:
			var i := y * w + x
			if rim[i] == 255:
				continue
			if top < 0 or s[i] > s[top]:
				top = i
			if b[i] >= s[i] - 1.0 and (bare < 0 or s[i] > s[bare]):
				bare = i
	var i := bare if bare >= 0 else top
	@warning_ignore("integer_division")
	return Vector2((i % w + 0.5) * 32.0 * params.dtheta(), -params.length / 2.0 + (i / w + 0.5) * params.macro_cell)


static func _md5(b: PackedByteArray) -> String:
	var ctx := HashingContext.new()
	ctx.start(HashingContext.HASH_MD5)
	ctx.update(b)
	return ctx.finish().hex_encode().left(8)


func _on_timed(pass_name: String, ms: float) -> void:
	if _started and pass_name == "detail":
		_detail.append(ms)


func _on_tiles(tiles: Array[Vector2i]) -> void:
	_tiles.append(tiles.size())
