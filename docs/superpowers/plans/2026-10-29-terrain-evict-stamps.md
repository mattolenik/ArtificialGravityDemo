# Terrain: stamps survive an eviction within the readback latency

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A tool stamp made within the stats readback latency of a window move is never lost, and its activity flag in flight never wakes the tile that takes its slot.

**Architecture:** Today a tool stamp (bore tick, deposit, push, tamp, spill, scoop, dump) leaves packing to the settle pack: the GPU flags the stamp's slot in the stats buffer, the flag lands two or three frames later, `TerrainSim.settle` makes the tile active, and the tile is packed into its blob once it has been quiet for `settle_time`. `Terrain._move_window` packs only the active tiles a move evicts, so a tile stamped in the frame or two before a teleport is evicted unpacked and the stamp is gone; the same stamp's flag can ride the move frame's readback onto the entering tile and activate it for a second. Two small changes close the class, both on the CPU: `EditLayer` remembers every tile a non-packing stamp touched until a pack is issued for it, and `Terrain` packs those tiles before an eviction and at exit, next to the active ones; and `TerrainSim.invalidate` asks for the stats at the old generation before it bumps it, so the flags in flight are consumed there (and ignored for the slots that change) instead of by the move frame's readback at the new generation. A new `evict` phase of the tool run proves both, with a stamp in the same frame as a 600 m teleport and one a frame before it.

**Tech Stack:** Godot 4.7.2, GDScript, the existing `edit.glsl` and `sim.glsl` (no shader change), Jolt; headless tests under `godot/tests/`, the windowed tool run through `godot/tests/offscreen.sh`.

**Spec:** `docs/superpowers/specs/2026-10-28-terrain-slice-3-design.md` ("Everything rides on the edit layer": stamps pack their tiles back as today; the anti-goal "Losing a pile or a puddle to a scroll, a teleport or a restart"), argued against the open items in `docs/superpowers/plans/2026-10-28-terrain-slice-3-followups.md` (line 14, the stamp whose flag has not landed when a teleport evicts its tile; line 30, the stamp after `Terrain._process` that activates the entering tile, closable by a readback at the old generation inside `invalidate`) and `docs/superpowers/plans/2026-10-27-terrain-edits-followups.md` (line 13, decision 4's accepted limit: a stamped tile evicted and re-entered within the readback applies its old blob).

## Global Constraints

- Godot 4.7.2 standard build, GDScript + GLSL compute on the main RenderingDevice, Jolt; no GDExtension.
- The slice 2 contracts: nothing dispatches GPU work or does file I/O from inside a readback callback; `buffer_update` and `buffer_clear` outside open compute lists; async readbacks after `compute_list_end`; the collider's issue order stays as it is.
- Headless tests cannot create a RenderingDevice: `EditLayer._stamp_rd`, `_pack_rd` and `TerrainSim._step_rd` return at an invalid `_set`, so the CPU bookkeeping is tested headless and the GPU behaviour by the tool run.
- GPU drivers run through `sh godot/tests/offscreen.sh <scene> </abs/log> [user args]`, never a bare windowed launch; the tool run runs on `user://worlds/tool_run`, and no driver touches `user://worlds/default`.
- `git` commands plain and one per call in the worktree; after any shader edit (none planned here) `godot --headless --path . --import` before a run, never chained after with `;`.
- Budgets stay: `sim` under 0.25 ms per active tile, `edit` and `pack` under 0.5 ms per list, GPU frame mean under 6 ms; one extra 68-byte stats readback per window move and one pack list per eviction of stamped tiles.

## Review Focus

1. A stamp with `pack` on (the debug dig) packs itself in its own list and must not also be remembered as unpacked, or every window move would pack it again: Task 1's test stamps once with `pack` on and expects nothing remembered.
2. The feet push every physics tick while walking, so the player's tile is remembered sixty times a second; the set must hold it once and a move must pack it once: Task 1's test checks the dictionary holds a tile once, Task 4's phase prints the pack lists of its moves.
3. A stamp on a tile that is also active must be packed once before eviction, not twice: Task 3 builds `leaving` with one filter over both conditions.
4. The extra readback inside `invalidate` must not pile up at a stalled renderer: moves happen only when the viewer's cell changes, which a held body cannot do, and Task 5 runs the blackout smoke to show no new ERROR line.
5. A quit right after a stamp loses it today by design ("a stamp whose readback has not landed at quit is lost"): Task 3's exit pack includes the stamped resident tiles, and Task 4 prints the count in the exit-pack line.

---

### Task 1: EditLayer remembers the tiles of unpacked stamps

**Files:**
- Modify: `godot/terrain/edit_layer.gd` (header lines 1-12; `stamp_op` lines 163-173; `pack_tiles` lines 212-214; `pack_tiles_sync` lines 218-220)
- Test: `godot/tests/test_edit_layer.gd`

**Interfaces:**
- Consumes: `EditLayer.stamp_tiles(window, cell, radius) -> Array[Vector2i]` (static), `EditLayer.Op` with `cell`, `radius`, `mode`, `amount`, `pack`, `reach()`.
- Produces: `var stamped := {}` on `EditLayer` (tile `Vector2i` → `true`: tiles a stamp that left packing to the settle pack has touched since a pack was last issued for them); `func unpacked(tiles: Array[Vector2i]) -> Array[Vector2i]` (those of `tiles` in `stamped`, in the order given). `pack_tiles` and `pack_tiles_sync` erase their tiles from `stamped` when they issue the pack.

- [ ] **Step 1: Write the failing test**

Append to `godot/tests/test_edit_layer.gd` before `if failed: quit(1)`:

```gdscript
	# Unpacked stamps are remembered per tile until a pack is issued for the tile (Terrain packs them before an
	# eviction and at exit): a tool stamp (pack off) marks the tiles its reach touches, once each however often
	# it is repeated; a debug stamp (pack on) packs itself and marks nothing. Headless: the stamp and pack
	# dispatches return at the invalid uniform set, the bookkeeping runs.
	var e := EditLayer.new()
	var tool_op := EditLayer.Op.new()
	tool_op.cell = Vector2i(127, 127); tool_op.radius = 3; tool_op.mode = EditLayer.MODE_DEPOSIT; tool_op.amount = 1.0; tool_op.pack = false
	e.stamp_op(w, tool_op)
	e.stamp_op(w, tool_op)
	check(e.stamped.size() == 4 and e.stamped.has(Vector2i(0, 0)) and e.stamped.has(Vector2i(1, 1)), "a tool stamp marks its four tiles unpacked, once: %s" % [e.stamped.keys()])
	check(e.unpacked([Vector2i(5, 5), Vector2i(0, 0), Vector2i(1, 0)]) == [Vector2i(0, 0), Vector2i(1, 0)], "unpacked keeps the marked tiles in order")
	e.pack_tiles(w, [Vector2i(0, 0), Vector2i(1, 0)])
	check(not e.stamped.has(Vector2i(0, 0)) and not e.stamped.has(Vector2i(1, 0)) and e.stamped.has(Vector2i(0, 1)) and e.stamped.has(Vector2i(1, 1)), "a pack forgets its tiles and keeps the others")
	e.pack_tiles_sync(w, [Vector2i(0, 1), Vector2i(1, 1)])
	check(e.stamped.is_empty(), "the sync pack forgets too")
	var dig := EditLayer.Op.new()
	dig.cell = Vector2i(200, 300); dig.radius = 5; dig.mode = EditLayer.MODE_RAISE; dig.amount = -0.25; dig.pack = true
	e.stamp_op(w, dig)
	check(e.stamped.is_empty(), "a stamp that packs itself marks nothing")
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `godot --headless --path godot --fixed-fps 60 --quit-after 7200 -s res://tests/test_edit_layer.gd`
Expected: a SCRIPT ERROR naming `stamped` (no such member), no `PASS` line.

- [ ] **Step 3: Implement the bookkeeping in `godot/terrain/edit_layer.gd`**

Declare, next to `stats_pending`:

```gdscript
## Tiles a stamp that left packing to the settle pack has touched since a pack was last issued for them, so
## Terrain can pack them before a window move evicts them and at exit: a stamp within the stats readback's
## latency of a move is not lost (the edits plan's decision 4 limit, closed by the evict-stamps plan).
var stamped := {}
```

In `stamp_op`, compute the reach's tiles always (`var touched := stamp_tiles(window, op.cell, op.reach())`), keep `tiles` for the pack only when `op.pack`, and when `op.pack` is false set `stamped[t] = true` for each touched tile. In `pack_tiles` and `pack_tiles_sync`, before dispatching, `for t in tiles: stamped.erase(t)`. Add:

```gdscript
## Those of tiles that hold a stamp no pack has seen yet.
func unpacked(tiles: Array[Vector2i]) -> Array[Vector2i]:
	return tiles.filter(func(t: Vector2i) -> bool: return stamped.has(t))
```

Rewrite the header's "Limit (decision 4)" sentence: a stamped tile evicted before its readback lands is packed before the move by Terrain (the `stamped` set), so a re-entry applies the stamped blob; the remaining limit is a settle pack still in flight at quit (the slice 3 follow-ups).

- [ ] **Step 4: Run the test to verify it passes**

Run: the command of Step 2. Expected: `PASS`.

- [ ] **Step 5: Commit**

```bash
git add godot/terrain/edit_layer.gd godot/tests/test_edit_layer.gd
git commit -m "Terrain: EditLayer remembers the tiles of unpacked stamps until a pack is issued for them (stamped, unpacked)"
```

### Task 2: TerrainSim.invalidate consumes the flags in flight at the old generation

**Files:**
- Modify: `godot/terrain/terrain_sim.gd` (header lines 1-9; `_step_rd` lines 193-222, its readback tail; `invalidate` lines 241-253)
- Test: `godot/tests/test_terrain_sim.gd`

**Interfaces:**
- Consumes: `invalidate(slots: Array[Vector2i])` (signature unchanged), `_on_stats(data, generation, asked)`.
- Produces: `func _read_stats_rd(generation: int) -> void` (render thread: records `last_asked_generation = generation`, then returns when `_rd` is null or `_set` invalid, else the readback bound to `generation` and the clear, exactly the tail `_step_rd` has today); `var last_asked_generation := -1` and `var stats_reads := 0` (readbacks asked, every path, for the test and the driver's summary).

- [ ] **Step 1: Write the failing test**

Append to `godot/tests/test_terrain_sim.gd` before the push-constant block (`# The push constants of sim.glsl`):

```gdscript
	# invalidate asks for the stats at the old generation before it bumps it: a stamp's flag in flight for an
	# evicted slot is consumed by that request and ignored when it lands (the slot changed), instead of riding
	# the move frame's readback, asked at the new generation, onto the tile that takes the slot. Without a
	# device the request is recorded and skipped.
	var reads := sim.stats_reads
	var gen := sim._generation
	sim.invalidate([Vector2i(2, 2)])
	check(sim.stats_reads == reads + 1 and sim.last_asked_generation == gen and sim._generation == gen + 1, "invalidate asks once, at the old generation, then bumps it")
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `godot --headless --path godot --fixed-fps 60 --quit-after 7200 -s res://tests/test_terrain_sim.gd`
Expected: a SCRIPT ERROR naming `stats_reads` or `last_asked_generation`, no `PASS` line.

- [ ] **Step 3: Implement in `godot/terrain/terrain_sim.gd`**

Move the tail of `_step_rd` (from `var frame := Engine.get_process_frames()` through `_rd.buffer_clear(_stats, 0, _stats_size)`) into `_read_stats_rd(generation: int)`, which first sets `last_asked_generation = generation` and `stats_reads += 1`, then returns when `_rd == null or not _set.is_valid()`, then does what the tail did; `_step_rd` calls `_read_stats_rd(generation)` after its lists. In `invalidate`, before `_generation += 1`, call `RenderingServer.call_on_render_thread(_read_stats_rd.bind(_generation))` (if the dummy server of a headless run refuses the call, call `_read_stats_rd(_generation)` directly when `_rd == null`). Keep `_waiting_since` and `_asked` bookkeeping inside `_read_stats_rd`, so the stall detector counts this request like any other. Update `invalidate`'s comment (the flags in flight are asked for now, at the old generation, and the landing ignores the changed slots) and the header's "read back after every frame that ran a list, a stamp or an apply" to add "and at every window move, before the slots change".

- [ ] **Step 4: Run the test to verify it passes**

Run: the command of Step 2. Expected: `PASS`.

- [ ] **Step 5: Commit**

```bash
git add godot/terrain/terrain_sim.gd godot/tests/test_terrain_sim.gd
git commit -m "Terrain: a window move asks for the stats at the old generation inside invalidate, so a flag in flight cannot wake the entering tile"
```

### Task 3: Terrain packs stamped tiles before an eviction and at exit

**Files:**
- Modify: `godot/terrain/terrain.gd` (`_move_window` lines 338-351; `_exit_tree` lines 262-266 and its comment; `_save_edits`'s comment lines 268-270)

**Interfaces:**
- Consumes: `window.edits.stamped`, `window.edits.unpacked(tiles)` (Task 1), `sim.is_active(tile)`, `sim.drop(tiles)`, `window.evicted_by(center)`, `window.is_resident(tile)`, `window.edits.pack_tiles(window, tiles)`, `pack_tiles_sync(window, tiles)`.
- Produces: nothing new; the tool run's `evict` phase (Task 4) is the test.

- [ ] **Step 1: Pack stamped tiles before eviction**

In `_move_window`, replace the `leaving` filter so a tile leaves packed when it is active or stamped:

```gdscript
	var evicted := window.evicted_by(center)
	# Active tiles, and tiles holding a stamp no pack has seen (its flag in flight, or landed but not yet
	# settled): packed now, before the move regenerates their slots, so nothing stamped is lost.
	var leaving: Array[Vector2i] = evicted.filter(func(t: Vector2i) -> bool: return sim.is_active(t) or window.edits.stamped.has(t))
	window.edits.pack_tiles(window, leaving)
	sim.drop(leaving)
```

- [ ] **Step 2: Pack stamped resident tiles at exit**

In `_exit_tree`, pack the active tiles plus the resident stamped ones in one synchronous call:

```gdscript
	if persist_edits and window != null:
		var tiles := sim.active_tiles()
		for t: Vector2i in window.edits.stamped:
			if window.is_resident(t) and not tiles.has(t):
				tiles.append(t)
		window.edits.pack_tiles_sync(window, tiles)
```

Update `_exit_tree`'s comment (the stamped tiles too, so a stamp made just before the quit is saved) and `_save_edits`'s ("A tile whose readback lands after _exit_tree's save is lost" stays true only for a settle pack still in flight; the stamp-in-flight case is packed synchronously now).

- [ ] **Step 3: Run the headless suite**

Run: `sh godot/tests/run.sh`
Expected: 18 `PASS` lines, no `ERROR` or `FAIL` line.

- [ ] **Step 4: Commit**

```bash
git add godot/terrain/terrain.gd
git commit -m "Terrain: a window move packs the evicted tiles that hold unpacked stamps, and the exit pack takes the stamped resident tiles"
```

### Task 4: The tool run's evict phase proves it; the notes record it

**Files:**
- Modify: `godot/terrain/tool_run.gd` (header: a paragraph after the `scroll` one, lines 89-93; `PHASES` line 123; the route after `_scroll`, lines 343-349; a new `_evict` after `_scroll`, which ends at line 1314; `_quit_active`'s exit-pack line)
- Modify: `docs/superpowers/plans/2026-10-28-terrain-slice-3-followups.md` (lines 14 and 30), `docs/superpowers/plans/2026-10-27-terrain-edits-followups.md` (line 13), `docs/terrain-research.md` (section 6.8, after the "Lake fill" paragraph)

**Interfaces:**
- Consumes: the driver's `_stamp`, `_op`, `_teleport`, `_settled_patch`, `_settled`, `_frames`, `_read`, `_vol`, `_box`, `_f`, `_residual`, `_report`; `_terrain.teleport(theta, z)`, `_terrain.sim.active_tiles()`, `_terrain.sim.stats_reads` (Task 2), `_terrain.window.is_resident`, `tile_of_cell`; `_center(c)`.
- Produces: `func _evict(from: Vector2i, spawn: Vector2i) -> bool`, the phase `evict` in `PHASES` and the route.

- [ ] **Step 1: Document the phase in the header**

After the `scroll` paragraph add:

```
## evict (S9: the first row from spawn_cell + (0, 60) outward whose five-cell plus is dry land, and S9' the same
##    from 40 rows past it, both clear of the slump and scroll piles): a 1 m³ deposit of radius 1 at S9 and, in the same frame, the player 600 m antispinward, clear of the seam phase's pile (S9's tile
##    evicted with the stamp's flag in flight); the same at S9' with one frame between the stamp and the move.
##    Six frames after each move no tile is active (the flag woke no entering tile); back at the spawn each
##    box of 6 holds its 1 m³ within 0.1 % at once (its tile was packed as it left, the blob re-applied) and
##    within 0.1 % once settled. The window's stats readbacks grew by exactly one per move.
```

- [ ] **Step 2: Add the phase to `PHASES` and the route**

`PHASES`: insert `"evict"` after `"scroll"`. In `_route`, after the scroll block and before `_phase = "restart"`:

```gdscript
	_phase = "evict"
	if not await _evict(spawn + Vector2i(0, 60), spawn):
		return
```

- [ ] **Step 3: Write `_evict`**

After `_scroll`:

```gdscript
## Phase evict from `from`: a stamp made in the frame of a window move, and one a frame before it, survive the
## eviction (packed as the tile leaves) and wake no entering tile (see the header). False after quitting on
## a timeout.
func _evict(from: Vector2i, spawn: Vector2i) -> bool:
	var window := _terrain.window
	var p := _terrain.params
	var away := spawn - Vector2i(roundi(600.0 / (p.radius * p.dtheta())), 0)
	var s9 := _dry_site(from)
	var sites: Array[Vector2i] = [s9, _dry_site(from + Vector2i(0, 40))]
	var evicted := true
	var woke := 0
	var reads := 0
	var at_once: Array[float] = []
	var settled: Array[float] = []
	for k in 2:
		var site := sites[k]
		var reads0 := _terrain.sim.stats_reads
		_stamp(_op(site, 1, EditLayer.MODE_DEPOSIT, 1.0))
		await _frames(k)
		var to := _center(away)
		_terrain.teleport(to.x, to.y)
		# Terrain._process moves the window in the next frame; the flag lands within three more.
		await _frames(6)
		woke += _terrain.sim.active_tiles().size()
		evicted = evicted and not window.is_resident(window.tile_of_cell(site.x, site.y))
		reads += _terrain.sim.stats_reads - reads0
		if not await _settled_patch():
			return false
		if not await _teleport(spawn):
			return false
		at_once.append(_vol(_read("loose"), _read("surface"), _box(site, 6)))
		var waited := await _settled(site)
		settled.append(_vol(_read("loose"), _read("surface"), _box(site, 6)) if waited >= 0.0 else -1.0)
	print("evict: stamps at %s (same frame) and %s (a frame before the move), 600 m away at %s, evicted: %s; active tiles 6 frames after the moves %d; back: %.6f and %.6f m³ at once (%+.4f %%, %+.4f %%), settled %.6f and %.6f m³; stats readbacks over the two moves %d" % [
			sites[0], sites[1], away, evicted, woke, at_once[0], at_once[1], _residual("evict same frame", at_once[0], 1.0),
			_residual("evict a frame before", at_once[1], 1.0), settled[0], settled[1], reads])
	_report("a stamp survives an eviction within its readback latency", evicted and woke == 0
			and absf(at_once[0] - 1.0) <= 1e-3 and absf(at_once[1] - 1.0) <= 1e-3
			and absf(settled[0] - 1.0) <= 1e-3 and absf(settled[1] - 1.0) <= 1e-3)
	return true


## The first cell from c outward along +z whose five-cell plus is dry land (no static water over any of its
## cells), within 64 rows; c itself when none is.
func _dry_site(c: Vector2i) -> Vector2i:
	var surface := _read("surface")
	var loose := _read("loose")
	var ws := _read("water_surface")
	for i in 64:
		var s := c + Vector2i(0, i)
		var dry := true
		for d in _disc(s, 1):
			dry = dry and _f(ws, d) <= _f(surface, d) + _f(loose, d) + 1e-3
		if dry:
			return s
	return c
```

The `reads` figure is printed, not asserted (two moves plus the move back each ask once; the frames between ask on activity too).

- [ ] **Step 4: Print the stamped tiles in the exit pack line**

In `_quit_active`, where the exit pack's line prints `exit pack: N active tiles [...] at quit, packed: ...`, add the count of `window.edits.stamped` resident tiles packed with them, so the restart phase's quit shows the stamped tiles went into the pack.

- [ ] **Step 5: Run the tool run before the fix lands, to see the phase fail (RED)**

On a scratch copy of the branch at Task 1's commit (or by temporarily reverting Task 3's `leaving` filter), run: `sh godot/tests/offscreen.sh res://terrain/tool_run.tscn /abs/log`
Expected: `a stamp survives an eviction within its readback latency: FAILED` with the at-once volumes near 0 and `woke` above 0; restore the fix afterwards. If running the phase red costs too much, note it in the ledger and rely on Step 6 alone.

- [ ] **Step 6: Run the tool run with the fix (GREEN)**

Run: `sh godot/tests/offscreen.sh res://terrain/tool_run.tscn /abs/log`
Expected: `PASS`, 0 `ERROR` lines, the evict line with both volumes 1.000000 within 0.1 %, `woke` 0, `evicted: true`, every earlier phase as before (the scroll's pile within 0.1 %, the restart's hole and loose kept).

- [ ] **Step 7: Record it**

In the slice 3 follow-ups, under lines 14 and 30, add "Closed 2026-10-29 by `2026-10-29-terrain-evict-stamps.md`: ..." with the phase's numbers; in the edits follow-ups under line 13, the same for decision 4's limit (the re-entry now applies the stamped blob; what stays is a settle pack in flight at quit). In `docs/terrain-research.md` 6.8, after the "Lake fill" paragraph, an "Eviction" paragraph: the rule (stamped tiles packed before eviction and at exit; the stats asked at the old generation inside `invalidate`), the phase's figures, and the cost (one 68-byte readback per move, one pack list per eviction of stamped tiles).

- [ ] **Step 8: Commit**

```bash
git add godot/terrain/tool_run.gd docs/superpowers/plans/2026-10-28-terrain-slice-3-followups.md docs/superpowers/plans/2026-10-27-terrain-edits-followups.md docs/terrain-research.md
git commit -m "Terrain: the tool run's evict phase proves a stamp survives an eviction within its readback latency and wakes no entering tile; notes closed"
```

### Task 5: Whole-branch verification

**Files:** none changed.

- [ ] **Step 1: Headless suite**

Run: `sh godot/tests/run.sh`. Expected: 18 `PASS`, no `ERROR` or `FAIL`.

- [ ] **Step 2: Blackout smoke**

Run: `sh godot/tests/offscreen.sh res://terrain/smoke.tscn /abs/log -- --blackout`. Expected: `BLACKOUT PASS`, 0 `ERROR` lines (the extra readback per move adds nothing while the body is held).

- [ ] **Step 3: Edit run and bake check**

Run: `sh godot/tests/offscreen.sh res://terrain/edit_run.tscn /abs/log`. Expected: `PASS`. The bake check is known to fail on the played default world (the slice 3 follow-ups); run it and confirm the failure is only its box drop, as before.

- [ ] **Step 4: Finish**

Use superpowers:finishing-a-development-branch: present the merge menu for `worktree-terrain-evict-stamps` against `terrain`.

## Review and fix round (2026-10-29)

The whole-branch review found one defect: the feet push every physics tick, a push over bare ground changes nothing and never activates its tile, so every tile walked across stayed in `stamped` and was packed into a 512 KiB blob at its eviction or at exit (the edit run's trench phase then packed its walked tiles at the scroll, and its collider check lost the pit). Fix: `stamped[t]` holds the count of stats readbacks asked when the stamp was made (`stamp_op(window, op, asked)`, Terrain passes `TerrainSim.stats_reads`), `TerrainSim.stats_landed` counts landings, and `EditLayer.forget_quiet(landed, is_active)`, called by `Terrain._process` after the step, forgets a stamp once a later readback has landed with its tile still quiet. Nits taken: `unpacked` deleted (nothing called it); a packing stamp forgets earlier stamps on its tiles; the `_rd == null` branch in `invalidate` dropped (the render-thread call runs synchronously headless); the evict phase's header and print name what is counted (the tile that took the slot, quiet unless its blob holds a pile); the exit-pack line counts resident stamped tiles. Not taken: printing the pack lists per move (the pack count is not exposed to the driver). The blackout smoke, the edit run and the bake check run on the played default world and two of them fail there on plain `terrain` too (the slice 3 follow-ups); the edit run passes on this branch once the walked tiles are no longer packed.
