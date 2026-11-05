## The ground inside the station: loads (or generates) the world, keeps the 1 m TerrainWindow around the
## viewer, and draws it as one tile mesh per window slot, each with a water mesh as its child, bent onto
## the cylinder by tile.gdshader and water.gdshader; FarTerrain draws beyond it, and a ColliderPatch under
## the viewer is the ground. The ground body (the viewer at the start) is held still until the first patch
## is live, then stood on it at the spawn site, and held again whenever the live patch does not cover it.
## Floating origin: the whole station moves along its axis in ORIGIN_STEP steps to keep the viewer near
## the global origin; terrain works in station space only. Place it under the Station at its origin, so
## its space is station space.
class_name Terrain
extends Node3D

## Emitted once the ground collider at the spawn site exists and the viewer stands on it.
signal collider_live
## Emitted after each floating-origin shift, with the station's z shift in m.
signal origin_shifted(shift: float)
## Emitted when Terrain starts or stops holding the ground body for want of a patch under it.
signal body_held(held: bool)

@export var station: Station
## The window follows this node.
@export var viewer: Node3D
## Directory under user://worlds/.
@export var world_name := "default"
## Window side in 1 m cells, a multiple of TerrainWindow.TILE.
@export var window_size := 512
## Whether edited tiles are saved to the world's tiles/ directory (edits are always loaded). Windowed test
## drivers set it false, so they never write into a real world.
@export var persist_edits := true
## The tunables of the tools and of the loose-dirt simulation; a default ToolParams when unset.
@export var tool_params: ToolParams

## The station shifts along its axis by whole steps of this many m once the viewer is farther than this
## from the global origin.
const ORIGIN_STEP := 1024.0
## Render layer mask of every terrain mesh: the LightBar lights the terrain through its own shaders and
## everything else through a plain directional light, split on this layer.
const RENDER_LAYER := 2
## Seconds between autosaves of the edited tiles that have been read back since the last one.
const SAVE_INTERVAL := 30.0
## Bodies in this group are held while no live collider patch covers them (the ground body always is).
const GROUND_GROUP := "terrain_ground"
## Meta key of a body's hold state: true while Terrain is holding it.
const HELD_META := "terrain_held"
## Frames after a tool stamp within which its tile's activity flag must land, or the stamp is forgotten. The
## stats readback took at most 3 measured; twice that, so a flag landing a few frames late does not stop the
## collider following a pile.
const RETOUCH_FRAMES := 6

var params: WorldParams
var maps: MacroMaps
var window: TerrainWindow
var patch: ColliderPatch
## The loose-dirt and sheet-water simulation over the window's active tiles.
var sim: TerrainSim
## The voxel box around the player's feet (the tunnels design): the owner of the ground and the loose dirt
## inside it; it packs its changed columns into the window every frame.
var box: VoxelBox
## Per-material numbers: swell, repose, porosity, wetting distance.
var materials: MaterialSet = preload("res://terrain/materials.tres")

## One ground mesh per slot, slot (x, y) at index y * slots + x; its child is the water mesh.
var _tiles: Array[MeshInstance3D] = []
var _center := Vector2i(-1, -1)
## Set once the first patch is live and the viewer is released.
var _live := false
## The node stood on the ground at spawn; the viewer may later become the FlyCamera.
var _body: Node3D
## Set by teleport() while the body waits, held, for a patch at its new place; cleared once stood on one.
var _teleporting := false
## The box's top as last sent to the ground tiles' material and the patch.
var _box_top := -1
## Where the viewer was stood at the spawn site, in station space.
var _spawn_at: Vector3
## Seconds since the edits were last saved.
var _since_save := 0.0
## The cells tool stamps never push loose dirt into (set_obstacle): within _obstacle_radius cells of
## _obstacle; none while the radius is negative.
var _obstacle := Vector2i(-1, -1)
var _obstacle_radius := -1
## The last tool stamp's centre and reach, re-touched while its tile is active (_retouch); the reach is -1
## while there is none. The process frame it was made in, and whether its tile has been active since.
var _last_tool := Vector2i(-1, -1)
var _last_reach := -1
var _last_frame := 0
var _last_active := false
## The one collider touch waiting for _flush_collider (last touch wins); none while the radius is -1.
var _touch_cell := Vector2i(-1, -1)
var _touch_radius := -1
## When _flush_collider last rebaked the edit shape, and last moved the zone, in s.
var _edit_at := -INF
var _zone_at := -INF

@onready var far: FarTerrain = $Far


func _ready() -> void:
	if tool_params == null:
		tool_params = ToolParams.new()
	_body = viewer
	_body.process_mode = PROCESS_MODE_DISABLED
	# Children are ready before their parent, so the station may not have measured its hull yet.
	if station.radius == 0.0:
		await station.ready
	_load_world()
	window = TerrainWindow.new()
	window.setup(params, maps, window_size)
	window.edits = EditLayer.new()
	window.edits.setup(window)
	sim = TerrainSim.new()
	sim.params = tool_params
	sim.materials = materials
	sim.setup(window, window.edits)
	box = VoxelBox.new()
	box.setup(window, window.edits, materials, tool_params)
	box.chunk_root = self
	box.chunk_material = _chunk_material()
	box.on_mask_changed = _on_chunk_mask
	# Before the first move_to, so the spawn tiles get their edits in their first dispatch.
	window.edits.blobs = WorldIO.load_edits(world_name)
	if not window.edits.blobs.is_empty():
		print("Loaded %d edited tiles" % window.edits.blobs.size())
	_tiles = make_tiles(self, window)
	far.setup(window)
	# The viewer's scene position is under the sea floor: start the windows and the patch at the spawn site.
	patch = ColliderPatch.new()
	add_child(patch)
	patch.live.connect(_on_first_live, CONNECT_ONE_SHOT)
	patch.live.connect(_on_live)
	var spawn := maps.spawn
	var cell := params.cell_of(spawn.x, spawn.y)
	_move_window(window.tile_of_cell(cell.x, cell.y))
	far.follow(cell)
	patch.rebuild(window, spawn.x, spawn.y)


## The station's z shift that brings a viewer at global z back within ORIGIN_STEP / 2 of the origin, in
## whole steps, once it is farther than ORIGIN_STEP; 0 until then.
static func origin_shift_for(viewer_global_z: float) -> float:
	if absf(viewer_global_z) <= ORIGIN_STEP:
		return 0.0
	return -roundf(viewer_global_z / ORIGIN_STEP) * ORIGIN_STEP


## One ground mesh per slot of w, slot (x, y) at index y * slots + x, each with a water mesh as its child,
## added under parent and reading w's textures.
static func make_tiles(parent: Node3D, w: TerrainWindow) -> Array[MeshInstance3D]:
	var mesh := PlaneMesh.new()
	mesh.size = Vector2.ONE * TerrainWindow.TILE
	mesh.subdivide_width = TerrainWindow.TILE - 1
	mesh.subdivide_depth = TerrainWindow.TILE - 1
	# The shaders move every vertex; every tile is drawn in the frame of the wanted set's middle (see
	# place_tiles), so this box holds the whole window in it, a cell of margin each way. Across, a vertex
	# sits up to R sin(a) from the middle, a = half the window plus half a cell of angle (314 m for the 1 m
	# window on the default world, 2266 m for the 8 m one); along, half the window plus half a cell; up,
	# under h_sea + h_mtn plus the curvature 2R sin^2(a / 2); down, a dry water vertex tucks 1 m under the
	# hull-level sea floor and a coarser level sinks a quarter cell.
	var p := w.params
	var a := (w.size / 2.0 + 0.5) * w.cell * p.dtheta()
	var across := p.radius * sin(a) + w.cell
	var along := (w.size / 2.0 + 1.5) * w.cell
	var top := p.h_sea + p.h_mtn() + 2.0 * p.radius * sin(a / 2.0) ** 2 + w.cell
	mesh.custom_aabb = AABB(Vector3(-across, -10, -along), Vector3(2.0 * across, top + 10, 2.0 * along))
	var ground := _material(preload("res://terrain/shaders/tile.gdshader"), w)
	ground.set_shader_parameter("material_tex", w.texture_rd("material"))
	ground.set_shader_parameter("material_color", preload("res://terrain/materials.tres").color)
	ground.set_shader_parameter("n_theta", w.params.n_theta())
	ground.set_shader_parameter("saturation_tex", w.texture_rd("saturation"))
	ground.set_shader_parameter("chunk_mask", w.texture_rd("chunk_mask"))
	ground.set_shader_parameter("z0", -w.params.length / 2.0)
	@warning_ignore("integer_division")
	ground.set_shader_parameter("n_chunks", w.params.n_theta() / VoxelBox.CHUNK)
	var water := _material(preload("res://terrain/shaders/water.gdshader"), w)
	var tiles: Array[MeshInstance3D] = []
	for i in w.slots * w.slots:
		var tile := MeshInstance3D.new()
		tile.mesh = mesh
		tile.material_override = ground
		tile.layers = RENDER_LAYER
		var wet := MeshInstance3D.new()
		wet.mesh = mesh
		wet.material_override = water
		wet.layers = RENDER_LAYER
		tile.add_child(wet)
		parent.add_child(tile)
		tiles.append(tile)
	return tiles


## Stands the viewer 2 m above the patch's centre, facing spinward with its up toward the axis, and lets
## it go.
func _on_first_live(center: Vector2) -> void:
	var up := Vector3(-sin(center.x), cos(center.x), 0)
	var forward := Vector3(cos(center.x), sin(center.x), 0)
	_spawn_at = Cyl.position(center.x, center.y, patch.center_height() + 2.0, params.radius)
	viewer.global_transform = station.global_transform * Transform3D(Basis(up.cross(-forward), up, -forward), _spawn_at)
	viewer.process_mode = PROCESS_MODE_INHERIT
	_live = true
	collider_live.emit()


func _load_world() -> void:
	var world := WorldIO.load_world(world_name)
	if world.is_empty():
		params = WorldParams.new()
		params.radius = station.radius
		params.length = station.length
		params.g_hull = station.acceleration
		print("Generating world '%s'..." % world_name)
		maps = MacroGenerator.new().generate(params, func(stage: String, fraction: float) -> void:
			print("  %3d%% %s" % [roundi(fraction * 100), stage]))
		var err := WorldIO.save(maps, params, world_name)
		if err != OK:
			push_error("Saving world '%s' failed: %s" % [world_name, error_string(err)])
		return
	params = world[0]
	maps = world[1]
	if not is_equal_approx(params.radius, station.radius):
		push_warning("World '%s' was made for radius %.1f m, the station's is %.1f m; using the world's." \
				% [world_name, params.radius, station.radius])


static func _material(shader: Shader, w: TerrainWindow) -> ShaderMaterial:
	var m := ShaderMaterial.new()
	m.shader = shader
	m.set_shader_parameter("surface_tex", w.texture_rd("surface"))
	m.set_shader_parameter("loose_tex", w.texture_rd("loose"))
	m.set_shader_parameter("water_tex", w.texture_rd("water_surface"))
	m.set_shader_parameter("depth_tex", w.texture_rd("water_depth"))
	m.set_shader_parameter("R", w.params.radius)
	m.set_shader_parameter("dtheta", w.params.dtheta())
	m.set_shader_parameter("cell", w.cell)
	m.set_shader_parameter("height_scale", TerrainWindow.HEIGHT_SCALE)
	m.set_shader_parameter("window_size", w.size)
	return m


## The floating-origin shift: everything in the world is under the station, so one move takes it all
## along. Moving the station re-sends every body's node transform to the physics server, so this runs
## here, where those transforms hold the latest physics state (from _process they are a step stale and a
## moving body would lose that step), and only when there is a shift (every frame would pin rigid bodies).
func _physics_process(_delta: float) -> void:
	if not _live:
		return
	var shift := origin_shift_for(viewer.global_position.z)
	if shift != 0.0:
		station.position.z += shift
		origin_shifted.emit(shift)


func _process(delta: float) -> void:
	if not _live:
		return
	_since_save += delta
	if _since_save >= SAVE_INTERVAL:
		_save_edits()
	var cell := viewer_cell()
	_move_window(window.tile_of_cell(cell.x, cell.y))
	far.follow(cell)
	# The box follows the feet (1 m under the body's origin, toward the hull), steps its loose dirt and packs
	# what changed before the water simulation reads the window.
	var q := station.to_local(_body.global_position)
	box.follow(q + Vector3(q.x, q.y, 0.0).normalized())
	box.step(delta)
	box.pack_dirty(sim.stats_reads)
	box.remesh_dirty(Time.get_ticks_msec() / 1000.0)
	if box.exists() and box.top() != _box_top:
		_box_top = box.top()
		# The band the chunks' meshes draw in: a voxel inside the box's floor and ceiling, where the mesh is
		# complete (its last crossing lies half a voxel in); the tiles draw the ground outside it.
		for m: ShaderMaterial in [_tiles[0].material_override, box.chunk_material]:
			m.set_shader_parameter("box_top", float(_box_top) - 1.0)
			m.set_shader_parameter("box_bottom", float(box.bottom()) + 1.0)
		patch.box_top = float(_box_top)
	# Settled tiles are packed after the step's lists, so the pack sees the last apply.
	var settled := sim.step(window, delta)
	if not settled.is_empty():
		window.edits.pack_tiles(window, settled)
	# A stamp whose later readback landed with its tile still quiet changed nothing: no pack is owed for it.
	window.edits.forget_quiet(sim.stats_landed, sim.is_active)
	# The collider follows the last tool's ground while the water there or the box's loose anywhere moves.
	_retouch(sim.is_active(window.tile_of_cell(_last_tool.x, _last_tool.y)) or box.has_active(), Engine.get_process_frames())
	_flush_collider(Time.get_ticks_msec() / 1000.0)
	var p := station.to_local(viewer.global_position)
	patch.issue_again(window)
	if patch.needs_rebuild(p):
		patch.rebuild(window, Cyl.theta_of(p), p.z)
	_hold_body(not covered(station.to_local(_body.global_position)))
	for b: Node3D in get_tree().get_nodes_in_group(GROUND_GROUP):
		_hold(b, not covered(station.to_local(b.global_position)))


## The reset-world button: the world's saved edits go (its generated maps stay, so the same world comes
## back fresh), nothing is saved on the way out (persist_edits off: _exit_tree and the autosave skip), and
## the main scene reloads with the player at the spawn.
func reset_world() -> void:
	persist_edits = false
	var err := WorldIO.wipe_edits(world_name)
	if err != OK:
		push_error("Wiping the edits of world '%s' failed: %s" % [world_name, error_string(err)])
	get_tree().reload_current_scene()


## With persist_edits, packs the active tiles and the resident tiles holding an unpacked stamp synchronously
## first, so a quit mid-slump keeps the pile and a stamp made just before the quit is saved; without, nothing
## is saved, so the synchronous readback is skipped.
func _exit_tree() -> void:
	if persist_edits and window != null:
		# The box's columns changed since its last pack (an op in the quit's frame) go into the window first,
		# so the tiles' pack below carries them.
		box.pack_all_sync()
		var tiles := sim.active_tiles()
		for t: Vector2i in window.edits.stamped:
			if window.is_resident(t) and not tiles.has(t):
				tiles.append(t)
		window.edits.pack_tiles_sync(window, tiles)
	_save_edits()


## Writes the tiles whose blobs have landed since the last save (all of window.edits.unsaved: no GPU wait,
## so a tile still being read back is saved by the next call) and forgets them once written. A settle pack
## whose readback lands after _exit_tree's save is lost: the exit does not wait for it (a stamp in flight is
## packed synchronously there instead).
func _save_edits() -> void:
	_since_save = 0.0
	if not persist_edits or window == null or window.edits.unsaved.is_empty():
		return
	var landed := {}
	for tile: Vector2i in window.edits.unsaved:
		landed[tile] = window.edits.blobs[tile]
	var err := WorldIO.save_edits(world_name, landed)
	if err != OK:
		push_error("Saving the edits of world '%s' failed: %s" % [world_name, error_string(err)])
		return
	window.edits.unsaved.clear()


## Holds _body while there is no ground under it, and lets it go once there is.
func _hold_body(hold: bool) -> void:
	if _hold(_body, hold):
		body_held.emit(hold)


## Holds a body (frozen, out of the physics space with its state) or releases it; the state is kept in its
## meta terrain_held. A body that something else already disabled (the FlyCamera freezing the player) is
## neither taken nor released. Returns whether anything changed.
func _hold(body: Node3D, hold: bool) -> bool:
	if hold == body.get_meta(HELD_META, false) or (hold and body.process_mode == PROCESS_MODE_DISABLED):
		return false
	body.set_meta(HELD_META, hold)
	body.process_mode = PROCESS_MODE_DISABLED if hold else PROCESS_MODE_INHERIT
	return true


## Moves the ground body to stand on the surface at (theta, z), with no velocity. Over the live patch it
## is stood on it at once; elsewhere it is put 2 m over the macro surface and held until a patch covers
## it, then stood on that (_on_live). Nothing before the first patch is live.
func teleport(theta: float, z: float) -> void:
	if not _live:
		return
	var p := Cyl.position(theta, z, height_at(theta, z) + 2.0, params.radius)
	if patch.covers(p):
		p = ground_point(p, 2.0)
	else:
		_teleporting = true
		_hold_body(true)
	if _body is CharacterBody3D:
		(_body as CharacterBody3D).velocity = Vector3.ZERO
	_body.global_position = station.global_transform * p


## Whether a teleported body is held 2 m over the macro surface, waiting for a patch to stand on.
func teleporting() -> bool:
	return _teleporting


## Stands a teleported body on the patch that has just landed under it.
func _on_live(_center: Vector2) -> void:
	if not _teleporting:
		return
	var p := station.to_local(_body.global_position)
	if not patch.covers(p):
		return
	_teleporting = false
	_body.global_position = station.global_transform * ground_point(p, 2.0)


## Moves the window to the tiles around center and points every tile node at its tile, if center changed.
## Active tiles and tiles holding an unpacked stamp that the move evicts are packed first (the active ones leave
## the simulation), so a pile mid-slump and a stamp within the readback latency are kept; the
## evicted tiles' slots are invalidated in the simulation's activity flags.
func _move_window(center: Vector2i) -> void:
	if center == _center:
		return
	_center = center
	var evicted := window.evicted_by(center)
	# The box's columns changed since its last pack go into the window first (the box lies inside the window,
	# so a tile it has bricks over never leaves; a far teleport moves the window under the box, and the box
	# follows from the new tiles).
	box.pack_all_sync()
	# Active tiles, and tiles holding a stamp no pack has seen (its flag in flight, or landed but not yet
	# settled): packed now, before the move regenerates their slots, so nothing stamped is lost.
	var leaving: Array[Vector2i] = evicted.filter(func(t: Vector2i) -> bool: return sim.is_active(t) or window.edits.stamped.has(t))
	window.edits.pack_tiles(window, leaving)
	sim.drop(leaving)
	var slots: Array[Vector2i] = []
	for t in evicted:
		slots.append(window.slot_of(t))
	sim.invalidate(slots)
	window.move_to(center)
	place_tiles(window, _tiles, center)


## Points every node of tiles (from make_tiles) at its tile of w's wanted set around center. All nodes
## share one transform, the frame on the hull at the wanted set's middle grid point, and each tile's
## `tile_offset` is its centre's offset from there in window cells (theta the short way round), so tiles
## that share an edge bend identical numbers in one frame and their edge vertices match bit for bit.
static func place_tiles(w: TerrainWindow, tiles: Array[MeshInstance3D], center: Vector2i) -> void:
	var wanted := w.wanted_tiles(center)
	@warning_ignore("integer_division")
	var mid := w.wanted_origin(center) * TerrainWindow.TILE + Vector2i.ONE * (w.size / 2)
	var theta := mid.x * w.cell * w.params.dtheta()
	var frame := Transform3D(
			Basis(Vector3(cos(theta), sin(theta), 0), Vector3(-sin(theta), cos(theta), 0), Vector3(0, 0, 1)),
			Cyl.position(theta, -w.params.length / 2.0 + mid.y * w.cell, 0, w.params.radius))
	@warning_ignore("integer_division")
	var half_around := w.tiles_around * TerrainWindow.TILE / 2
	for n in wanted.size():
		var t := wanted[n]
		var s := w.slot_of(t)
		var tile := tiles[s.y * w.slots + s.x]
		tile.transform = frame
		var c := w.tile_center(t)
		@warning_ignore("integer_division")
		var k := t * TerrainWindow.TILE + Vector2i.ONE * (TerrainWindow.TILE / 2) - mid
		var offset := Vector2i(wrapi(k.x, -half_around, half_around), k.y)
		@warning_ignore("integer_division")
		var edge := Vector2i(_edge(n % w.slots, w.slots), _edge(n / w.slots, w.slots))
		for g: GeometryInstance3D in [tile, tile.get_child(0)]:
			g.set_instance_shader_parameter("tile_theta", c.x)
			g.set_instance_shader_parameter("tile_z", c.y)
			g.set_instance_shader_parameter("tile_offset", offset)
			g.set_instance_shader_parameter("slot_origin", w.texel_origin(t))
			g.set_instance_shader_parameter("clamp_edge", edge)


## -1 for the first of the wanted set's rows or columns, +1 for the last, 0 between.
static func _edge(i: int, slots: int) -> int:
	return -1 if i == 0 else (1 if i == slots - 1 else 0)


## Raises (dh > 0) or lowers (dh < 0) the ground in a disc around the cell at (theta, z) by dh m at its
## centre with a parabolic falloff to its edge (EditLayer.stamp; decision 7 of the terrain edits plan).
## radius is in cells, not metres, and at most 64 (four tiles): a cell is 1 m along the axis and (R - h) dtheta
## across, 1.23 m on the hull and 0.64 m at h_sea + h_mtn with the default WorldParams, so the disc is an
## ellipse in metres. Digging cuts the strata down with the surface; raising adds dirt. The collider follows
## from the next frame (ColliderPatch.on_edit). False, and nothing changes, before the first patch is live,
## for a radius out of range, when the disc is wholly off the station's ends, or when it is not wholly inside
## the 1 m window.
func edit(theta: float, z: float, radius: float, dh: float) -> bool:
	var r := ceili(radius)
	# r >= TILE is refused before stamp_tiles, which loops over every tile of the box.
	if not _live or r < 0 or r >= TerrainWindow.TILE:
		return false
	var cell := params.cell_of(theta, z)
	var tiles := EditLayer.stamp_tiles(window, cell, r)
	# Empty: the disc is wholly off the station's ends. From r = 65 the box can span three tiles per axis,
	# more than the pack's slots.
	if tiles.is_empty() or tiles.size() > EditLayer.DOWN_SLOTS:
		return false
	for t in tiles:
		if not window.is_resident(t):
			return false
	window.edits.stamp(window, cell, r, dh)
	box.reload(EditLayer.disc(cell, r, params.n_theta()))
	patch.on_edit(cell, r)
	return true


## Whether a tool stamp reaching `reach` cells around cell may run now: edit's residency rule (live, reach under
## a tile, the box's tiles at most DOWN_SLOTS and all resident) and, unlike edit, the box wholly on the
## station, so a tool never places part of a disc off the world.
func can_stamp(cell: Vector2i, reach: int) -> bool:
	if not _live or reach < 0 or reach >= TerrainWindow.TILE or cell.y - reach < 0 or cell.y + reach >= params.n_z():
		return false
	var tiles := EditLayer.stamp_tiles(window, cell, reach)
	return not tiles.is_empty() and tiles.size() <= EditLayer.DOWN_SLOTS and tiles.all(window.is_resident)


## Runs a tool stamp (EditLayer.stamp_op) with the obstacle set_obstacle gave, unless can_stamp refuses it
## (false, nothing changes). A bore, deposit or spill touches the collider there (_collider_touch, decision
## 10). A tamp does not: it may change nothing (bare ground: a landing there would send an edit bake and move the
## zone); one that changed
## loose flags its tile, and the simulation re-touches the last stamp's place while that tile is active
## (_retouch).
func stamp_tool(op: EditLayer.Op) -> bool:
	if not can_stamp(op.cell, op.reach()):
		return false
	op.obstacle = _obstacle
	op.obstacle_radius = _obstacle_radius
	window.edits.stamp_op(window, op, sim.stats_reads)
	# A window-side stamp that moves dirt is followed by the box reading those columns again (one owner).
	if op.mode != EditLayer.MODE_SPILL:
		box.reload(EditLayer.disc(op.cell, op.reach(), params.n_theta()))
	_last_tool = op.cell
	_last_reach = op.reach()
	_last_frame = Engine.get_process_frames()
	_last_active = false
	if op.mode != EditLayer.MODE_TAMP:
		_collider_touch(op.cell, op.reach())
	return true


## A box op (Tools, through VoxelBox) changed the ground within reach cells of cell: the collider follows as it
## does after a tool stamp (_collider_touch when `now`, and _retouch while the tile is active either way; the
## feet pass false, as their stamps did: a landing must not rebake the edit shape).
func touch(cell: Vector2i, reach: int, now := true) -> void:
	for t in EditLayer.stamp_tiles(window, cell, reach):
		window.edits.stamped[t] = sim.stats_reads
	_last_tool = cell
	_last_reach = reach
	_last_frame = Engine.get_process_frames()
	_last_active = false
	if now:
		_collider_touch(cell, reach)


## Whether station-space p is over ground that collides: the patch covers it, or a touched chunk of the box
## holds the column under it with its mesh landed (the tunnels design).
func covered(p: Vector3) -> bool:
	return patch.covers(p) or box.covers(p)


## The station-space point `lift` m over the ground under station-space p: the patch's surface where it has
## one; where it has none (over a chunk drawn by its mesh the bake is NaN) the first collider a ray down
## from 20 m over the macro surface meets within 100 m, the body itself excluded; p when nothing is under it.
func ground_point(p: Vector3, lift: float) -> Vector3:
	if patch.covers(p):
		var q := patch.surface_point(p, lift)
		if q.is_finite():
			return q
	var theta := Cyl.theta_of(p)
	var hit := ground_below(Cyl.position(theta, p.z, height_at(theta, p.z) + 20.0, params.radius), 100.0)
	return hit + Vector3(-sin(theta), cos(theta), 0.0) * lift if hit.is_finite() else p


## The first collider a ray from station-space p meets within reach m toward the hull, the body itself
## excluded: the point, station-space, or INF with none (the tunnels design's clearance and unbury rules
## inside a chunk's mesh, where only what lies under the feet counts).
func ground_below(p: Vector3, reach: float) -> Vector3:
	var theta := Cyl.theta_of(p)
	var up := Vector3(-sin(theta), cos(theta), 0.0)
	var ray := PhysicsRayQueryParameters3D.create(station.global_transform * p, station.global_transform * (p - up * reach))
	if _body is PhysicsBody3D:
		ray.exclude = [(_body as PhysicsBody3D).get_rid()]
	var hit := get_world_3d().direct_space_state.intersect_ray(ray)
	return station.to_local(hit.position) if not hit.is_empty() else Vector3.INF


## The touched chunks' material (chunk.gdshader): the tiles' colours and speckle on the box's meshes.
func _chunk_material() -> ShaderMaterial:
	var m := ShaderMaterial.new()
	m.shader = preload("res://terrain/shaders/chunk.gdshader")
	m.set_shader_parameter("material_color", materials.color)
	m.set_shader_parameter("dtheta", params.dtheta())
	m.set_shader_parameter("z0", -params.length / 2.0)
	m.set_shader_parameter("n_theta", params.n_theta())
	m.set_shader_parameter("R", params.radius)
	return m


## A chunk's mesh landed or went: the collider over it follows (the bake takes NaN there).
func _on_chunk_mask(ch: Vector2i) -> void:
	@warning_ignore("integer_division")
	var half := VoxelBox.CHUNK / 2
	_collider_touch(Vector2i(posmod(ch.x * VoxelBox.CHUNK + half, params.n_theta()), ch.y * VoxelBox.CHUNK + half), half)


## Keeps tool stamps and the simulation from moving loose dirt or water into the cells within radius cells
## of cell (the standing auger's shaft); a negative radius clears it. The tiles under the old obstacle are
## activated, so a pile held against it slumps on once it goes (decision 3).
func set_obstacle(cell: Vector2i, radius: int) -> void:
	if _obstacle_radius >= 0:
		sim.activate(EditLayer.stamp_tiles(window, _obstacle, _obstacle_radius + 1))
		box.activate_cells(EditLayer.disc(_obstacle, _obstacle_radius + 1, params.n_theta()))
	_obstacle = cell
	_obstacle_radius = radius
	sim.obstacle = cell
	sim.obstacle_radius = radius
	box.obstacle = cell
	box.obstacle_radius = radius


## A slumping pile, or a push that moved loose, reaches the collider through the last tool stamp's place:
## re-touched every frame while that place's tile is active (active, from the simulation's flags). Forgotten
## once the tile leaves the active set (the pile settled), or when it has not become active RETOUCH_FRAMES
## frames after the stamp (the stamp changed nothing, a push or tamp over bare ground), so a stale stamp
## never steers the zone while some other tile is active.
func _retouch(active: bool, frame: int) -> void:
	if _last_reach < 0:
		return
	if active:
		_last_active = true
		_collider_touch(_last_tool, _last_reach)
	elif _last_active or frame - _last_frame > RETOUCH_FRAMES:
		_last_reach = -1


## Records a change of `radius` cells around cell for the collider; _flush_collider passes it on. One touch
## waits at a time: the last one wins.
func _collider_touch(cell: Vector2i, radius: int) -> void:
	_touch_cell = cell
	_touch_radius = radius


## The collider throttle (decision 10): passes the waiting touch to patch.on_edit at most every
## collider_edit_interval while the zone holds it, and at most every collider_zone_interval when it would
## move the zone; the first touch goes at once. A touch that must wait stays for a later frame.
func _flush_collider(now: float) -> void:
	if _touch_radius < 0:
		return
	var holds := patch.has_zone and ColliderPatch.zone_holds(patch.zone, _touch_cell, _touch_radius, params.n_theta())
	if (holds and now - _edit_at < tool_params.collider_edit_interval) \
			or (not holds and now - _zone_at < tool_params.collider_zone_interval):
		return
	if not holds:
		_zone_at = now
	patch.on_edit(_touch_cell, _touch_radius)
	_edit_at = now
	_touch_radius = -1


## Surface height in m at (theta, z), bilinear from the 32 m macro map: approximate, no detail, no edits and
## no loose dirt. In game it only lifts a held body 2 m over the ground before a patch lands.
func height_at(theta: float, z: float) -> float:
	return maps.sample(maps.surface, theta, z, params)


## Station-space point where the viewer was stood at the spawn site once the first patch is live; until
## then, 2 m above the macro surface there.
func spawn_position() -> Vector3:
	if _live:
		return _spawn_at
	return Cyl.position(maps.spawn.x, maps.spawn.y, height_at(maps.spawn.x, maps.spawn.y) + 2.0, params.radius)


## The 1 m cell (theta index, z index) under the viewer.
func viewer_cell() -> Vector2i:
	var p := station.to_local(viewer.global_position)
	return params.cell_of(Cyl.theta_of(p), p.z)
