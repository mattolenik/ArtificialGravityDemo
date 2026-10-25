# Godot Port Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A Godot 4.7 + Jolt version of the artificial-gravity demo in `godot/`, next to the
Unity project: the 3.2 km cylinder, rotating-frame gravity and drag, the box emitter with
trails, and the upright player.

**Architecture:** One `Station` node owns the physics maths and exposes it as functions
(`acceleration_at`, `drag_force`, `down_at`). Each body asks the station for its forces every
physics step, so there's no capture/release registry. Boxes are `RigidBody3D`s. The player is
a `CharacterBody3D` that adds the station acceleration to its own velocity. The Unity Inspector
buttons become an in-game panel. Parameters are tuned live through Godot's Remote scene tree
inspector while the game runs.

**Tech Stack:** Godot 4.7.2 standard build (`/opt/homebrew/bin/godot`), GDScript, Jolt Physics,
Blender 5.2 (one-time glTF export only). GDScript instead of C#: there's no build step, it
keeps a web export possible (the feasibility doc flags C# web export as experimental), and
headless tests run with one command.

**Spec:** [docs/godot-port-feasibility.md](../../godot-port-feasibility.md) (also
[docs/contact-solvers.md](../../contact-solvers.md))

## Global Constraints

- Godot project lives in `godot/`. The Unity project in `Assets/` is left untouched.
- `project.godot` `[physics]`: `3d/physics_engine="Jolt Physics"`, `3d/default_gravity=0.0`,
  `3d/default_linear_damp=0.0`, `3d/default_angular_damp=0.0`. Godot's default damping of 0.1
  would quietly slow every falling box. Physics ticks stay at Godot's default of 60 Hz (Unity
  used 50 Hz).
- 1 unit = 1 m. The station spins about its local **+Z** (`axis = Vector3(0, 0, 1)`), same as Unity.
- **`Vector3.FORWARD` is −Z in Godot** (Unity's `Vector3.forward` is +Z). Write
  `Vector3(0, 0, 1)` or `Vector3.BACK` wherever the Unity code says `Vector3.forward`.
- Station defaults, copied from Unity: `acceleration = 9.8`, `air_density = 1.225`,
  `air_pressure = 101325.0`.
- Emitter defaults: distance_from_axis 0, angle_around_axis 0, count 1, spread 10,
  box_size 5, density 8, drag_coefficient 1.05, trail_width 1.16, trail_time 100,
  direction RANDOM, min_speed 0.2, max_speed 0.8.
- Cameras: far clip `35000`.
- Every test is a `extends SceneTree` script in `godot/tests/` with its own
  `var failed := false` and `func check(ok: bool, msg: String)`, which calls `push_error(msg)`
  and sets `failed` when `ok` is false. Each test ends with `quit(1)` if `failed`, or
  otherwise `print("PASS")` and `quit(0)`. `godot/tests/run.sh` runs all of them. Tests run
  with `--fixed-fps 60`, so each frame is exactly one physics tick and they run faster than
  real time.
- Not ported, because nothing uses them in `oneill.unity`: `DragMouseOrbit`, `KeepAwake`,
  `SleepThreshold`, `Timescale`, `Extensions`, the Standard Assets, and the inactive
  first-person camera.

## Review Focus

1. **Spawning or standing on the spin axis.** The emitter's default `distance_from_axis` is 0.
   `down_at` must return `Vector3.ZERO` there rather than NaN, and the box should float at
   rest. Tested in Task 2.
2. **Boxes of different sizes sharing one shape.** In Godot, resources in a scene are shared
   between instances, so resizing one box's `BoxShape3D` would resize every box. Tested in
   Task 3.
3. **A box freed by something other than Clear,** for example `queue_free` from the remote
   inspector. `spawned_count()` and `clear_spawned()` must skip it. Tested in Task 3.
4. **The player anywhere except the bottom of the cylinder,** where "down" isn't −Y in world
   space. Must still land, stand upright and not drift. Tested in Task 5 at 0°, 90° and 180°.
5. **A spawn point outside the floor.** The info text must warn about it, as Unity's HelpBox
   did. Tested in Task 3.

---

### Task 1: Project skeleton and the gravity maths

**Files:**
- Create: `godot/project.godot`, `godot/station.gd`, `godot/tests/run.sh`, `godot/tests/test_drop_math.gd`
- Modify: `.gitignore` (add `godot/.godot/`)

**Interfaces:**
- Produces: `class_name Station extends Node3D` with
  `@export var acceleration := 9.8`, `@export var axis := Vector3(0, 0, 1)`,
  `@export var air_density := 1.225`, `@export var air_pressure := 101325.0`,
  `static func fictitious_acceleration(offset: Vector3, velocity: Vector3, omega: Vector3) -> Vector3`,
  `static func air_density_at(r: float, radius: float, omega: float, floor_density: float, floor_pressure: float) -> float`

- [ ] **Step 1: Create `godot/project.godot`** with `config_version=5`,
  `config/name="Artificial Gravity"`, `config/features=PackedStringArray("4.7", "Forward Plus")`
  and the `[physics]` block from Global Constraints. Add `godot/.godot/` to `.gitignore`.

- [ ] **Step 2: Write `godot/tests/run.sh`**

```sh
#!/bin/sh
# Runs every headless test; fails if any test errors, hangs, or doesn't print PASS.
cd "$(dirname "$0")/.." || exit 1
godot --headless --path . --import >/dev/null 2>&1
status=0
for t in tests/test_*.gd; do
  out=$(godot --headless --path . --fixed-fps 60 --quit-after 7200 -s "res://$t" 2>&1)
  echo "$out" | tail -n 3
  echo "$out" | tail -n 1 | grep -q '^PASS' || { echo "FAIL $t"; status=1; }
done
exit $status
```

- [ ] **Step 3: Write the failing test `godot/tests/test_drop_math.gd`.** This ports
  `ArtificialGravityTests.DropLandsAntispinward` with `dt = 1.0 / 60.0`.

```gdscript
extends SceneTree

func _initialize() -> void:
	var R := 500.0; var h := 10.0; var g := 9.8; var dt := 1.0 / 60.0
	var w := sqrt(g / R)
	var a := R - h
	var chord := sqrt(R * R - a * a)
	var expected_time := chord / (w * a)
	var expected_lag := (w * expected_time - atan(chord / a)) * R
	# Spin is about +Z, so spinward at the bottom of the cylinder is +X.
	var omega := Vector3(0, 0, w)
	var p := Vector3(0, -a, 0); var v := Vector3.ZERO; var t := 0.0
	while p.length() < R:
		v += Station.fictitious_acceleration(p, v, omega) * dt
		p += v * dt
		t += dt
	var lag := -atan2(p.x, -p.y) * R
	print("fall %.3fs (exact %.3fs), lands %.3fm antispinward (exact %.3fm)" % [t, expected_time, lag, expected_lag])
	if absf(t - expected_time) > 2 * dt or absf(lag - expected_lag) > 0.05 * expected_lag:
		check(false, "drop mismatch")
	# About 3% thinner at the axis of a 500 m, 1 g station.
	var ratio := Station.air_density_at(0.0, R, w, 1.225, 101325.0) / 1.225
	check(ratio > 0.96 and ratio < 0.98, "air density ratio %f" % ratio)
	if failed: quit(1)
	else: print("PASS"); quit(0)
```

- [ ] **Step 4: Run it and check it fails.**
  Run: `sh godot/tests/run.sh`
  Expected: `FAIL tests/test_drop_math.gd` (`Station` is not defined yet).

- [ ] **Step 5: Write the two static functions in `godot/station.gd`.** Port them from
  `Assets/ONeillCylinder.cs:91-107` unchanged. `Vector3.Cross(a, b)` becomes `a.cross(b)`,
  `Mathf.Exp` becomes `exp`. Add the four exports. Keep the class doc comment from
  `ONeillCylinder`.

- [ ] **Step 6: Run the test and check it passes.**
  Run: `sh godot/tests/run.sh`
  Expected: `fall 1.450s (exact 1.450s), lands 1.361m antispinward (exact 1.362m)`, then `PASS`.

- [ ] **Step 7: Commit**

```bash
git add .gitignore godot/project.godot godot/station.gd godot/tests
git commit -m "Godot port: project skeleton and rotating-frame maths with drop test"
```

---

### Task 2: Station scene, boxes, and the Jolt drop test (the proof of concept)

**Files:**
- Create: `godot/oneill.glb`, `godot/station.tscn`, `godot/oneill_grid.tres`, `godot/textures/GridEmissive.png`, `godot/textures/SwatchNavyAlbedo.png`, `godot/box.gd`, `godot/box.tscn`, `godot/tests/test_station.gd`
- Modify: `godot/station.gd`, `docs/godot-port-feasibility.md`

**Interfaces:**
- Consumes: the Task 1 `Station` statics.
- Produces:
  - `Station`: `var radius: float` (set in `_ready`),
    `func omega() -> Vector3`,
    `func down_at(pos: Vector3) -> Vector3` (unit vector pointing outward from the axis, or
    `Vector3.ZERO` on the axis),
    `func acceleration_at(pos: Vector3, vel: Vector3) -> Vector3`,
    `func drag_force(pos: Vector3, vel: Vector3, drag_area: float) -> Vector3` (N). All
    positions are global.
  - `class_name Box extends RigidBody3D`: `var station: Station` (set before `add_child`),
    `var drag_area := 0.0`,
    `func setup(size: float, density: float, drag_coefficient: float) -> void`.
  - `box.tscn`: root `Box` with children `CollisionShape3D` (BoxShape3D) and `MeshInstance3D`
    (BoxMesh).

- [ ] **Step 1: Export the cylinder.** Unity uses `oneill plain`, and the `.fbx` is out of date.

Run: `/Applications/Blender.app/Contents/MacOS/Blender -b "Assets/oneill plain.blend" --python-expr "import bpy; bpy.ops.export_scene.gltf(filepath='godot/oneill.glb', export_format='GLB', export_apply=True)"`
Expected: a 3.5 MB `godot/oneill.glb` with mesh bounds ±3200 × ±16000 × ±3200. The long axis
comes out along **Y**.

- [ ] **Step 2: Build `godot/station.tscn`.** Root `Station` (station.gd) with the `oneill.glb`
  instance as a child, rotated `Vector3(PI / 2, 0, 0)` so its long axis lies along the
  station's Z. Copy the two textures from `Assets/Standard Assets/Prototyping/Textures/`.
  `oneill_grid.tres` is a `StandardMaterial3D`: albedo texture `SwatchNavyAlbedo.png`,
  emission enabled with texture `GridEmissive.png` and energy 1.33, `uv1_scale = Vector3(1100, 2200, 1)`.
  These values come from `Assets/ONeillGrid.mat`.

- [ ] **Step 3: Write the failing test `godot/tests/test_station.gd`.** It instantiates
  `station.tscn` under `root` and waits two `physics_frame`s. Then:

```gdscript
	# Mesh imported the right way round
	check(absf(station.radius - 3200.0) < 1.0, "radius %f" % station.radius)
	# Review Focus 1: on the axis
	check(station.down_at(Vector3(0, 0, 5)) == Vector3.ZERO, "down on axis")
	check(station.acceleration_at(Vector3(0, 0, 5), Vector3.ZERO) == Vector3.ZERO, "accel on axis")
	check(station.down_at(Vector3(0, -100, 0)).is_equal_approx(Vector3(0, -1, 0)), "down at bottom")
```

  Then the real drop. Cast a ray (`root.world_3d.direct_space_state.intersect_ray`) from
  `(0, -3100, 0)` to `(0, -3300, 0)` to find the floor radius `floor_r` below the spawn point.
  The floor is faceted, so this is a little less than `radius`. Spawn a `Box` with
  `setup(0.1, 8, 0)`, `contact_monitor = true` and `max_contacts_reported = 1`, at rest at
  radius `land_r - 10`, where `land_r = floor_r - 0.05` (the box's half size). Count physics
  frames until `body_entered` fires, then measure `lag = -atan2(p.x, -p.y) * land_r`. Compare
  with the exact answer for a given ω, start radius `a` and landing radius `land_r`:
  `chord = sqrt(land_r² − a²)`, `time = chord / (ω·a)`, `lag = (ω·time − atan(chord / a))·land_r`.
  Use the same tolerances as Task 1 (time within `2 * dt`, lag within 5%). Print both results.
  Also wait 5 more seconds and print `box.sleeping` without asserting it. That answers the
  doc's "do bodies sleep under a constant force?" question.

- [ ] **Step 4: Run it and check it fails.** Run: `sh godot/tests/run.sh`. Expected: `FAIL tests/test_station.gd`.

- [ ] **Step 5: Implement the station instance methods and `Box`.**
  - `_ready`: find the `MeshInstance3D`, set `radius = mesh.get_aabb().end.x`, and assign
    `oneill_grid.tres` as its `material_override`. Then add a `StaticBody3D` holding a
    `CollisionShape3D` with `mesh.create_trimesh_shape()`, and set the shape's
    `backface_collision = true`, because boxes hit the mesh from the inside. Add the
    `StaticBody3D` as a child of the `MeshInstance3D`, not of the station, so it picks up the
    90° rotation.
  - `omega()`: `global_basis * axis.normalized() * sqrt(acceleration / radius)`.
  - `down_at(pos)`: `(pos - global_position).slide(omega().normalized()).normalized()`.
    `normalized()` of a zero vector is zero, which covers the axis.
  - `drag_force`: ported from `ONeillCylinder.Attract`. Air density comes from
    `air_density_at` at the radial distance.
  - `Box._physics_process`:
    `apply_central_force(mass * station.acceleration_at(global_position, linear_velocity) + station.drag_force(global_position, linear_velocity, drag_area))`.
  - `Box.setup`: give the box **new** `BoxShape3D` and `BoxMesh` resources of edge `size`.
    Set `mass = density * size³` and `drag_area = drag_coefficient * size²`.

- [ ] **Step 6: Run the tests and check they pass.** Run: `sh godot/tests/run.sh`.
  Expected: both tests `PASS`. The Jolt drop lands about 0.53 m antispinward.

- [ ] **Step 7: Record the findings** in `docs/godot-port-feasibility.md` under "Risks and
  unknowns": the measured landing lag and time, and whether the box went to sleep.

- [ ] **Step 8: Commit**

```bash
git add godot docs/godot-port-feasibility.md
git commit -m "Godot port: station scene, boxes, Jolt drop test"
```

---

### Task 3: Emitter, debug panel, and spawn-point camera

**Files:**
- Create: `godot/emitter.gd`, `godot/main.tscn`, `godot/tests/test_emitter.gd`
- Modify: `godot/project.godot` (`run/main_scene="res://main.tscn"`)

**Interfaces:**
- Consumes: `Station`, `Box.setup`, `Box.station`, `box.tscn`.
- Produces: `class_name Emitter extends Node3D` (a child of the station; only its local Z is
  used, as in Unity) with
  `enum LaunchDirection { RANDOM, SPINWARD, ANTISPINWARD, TOWARD_AXIS, TOWARD_FLOOR }`,
  the exports from Global Constraints plus `@export var station: Station`,
  `@export var box_scene: PackedScene`, `@export var info_label: Label`,
  `@export var spawn_camera: Camera3D`, and
  `func spawn() -> void`, `func clear_spawned() -> void`, `func spawned_count() -> int`,
  `func spawn_point() -> Vector3`, `func spawn_up() -> Vector3`, `func spinward() -> Vector3`
  (all three global), `func info_text() -> String`, `func toggle_spawn_view() -> void`.

- [ ] **Step 1: Write the failing test `godot/tests/test_emitter.gd`.** It instantiates
  `station.tscn`, adds an `Emitter` (with a `Camera3D`) as a child at local z = 0, and waits
  for a physics frame. Set `box_scene = load("res://box.tscn")`, `distance_from_axis = 100`, `count = 3`, `box_size = 2`,
  `direction = SPINWARD`, `min_speed = max_speed = 0.5`, then call `spawn()`:

```gdscript
	var boxes := station.get_children().filter(func(n): return n is Box)
	check(emitter.spawned_count() == 3, "count")
	for b in boxes:
		check(is_equal_approx(b.mass, 8.0 * 8.0), "mass")
		check(is_equal_approx(b.drag_area, 1.05 * 4.0), "drag area")
		check(b.linear_velocity.is_equal_approx(Vector3(0.5, 0, 0)), "spinward is +X at the bottom")
		check(b.global_position.distance_to(emitter.spawn_point()) <= 10.0, "spread")
	# Review Focus 2: shapes aren't shared
	emitter.count = 1; emitter.box_size = 4; emitter.spawn()
	check(boxes[0].get_node("CollisionShape3D").shape.size == Vector3.ONE * 2, "first box kept its size")
	# Review Focus 3: freed elsewhere
	boxes[1].queue_free(); await process_frame
	check(emitter.spawned_count() == 3, "freed box not counted")
	emitter.clear_spawned(); await process_frame
	check(emitter.spawned_count() == 0, "cleared")
	# Readout, and Review Focus 5
	check(emitter.info_text().contains("%.2f m/s²" % (9.8 * 100 / station.radius)), "gravity readout")
	emitter.distance_from_axis = 3199
	check(emitter.info_text().contains("outside the floor"), "outside warning")
	# Handedness: spinward shows on the right of the spawn view, as in Unity
	emitter.toggle_spawn_view()
	check(emitter.spawn_camera.global_basis.x.dot(emitter.spinward()) > 0.99, "spinward on the right")
```

- [ ] **Step 2: Run it and check it fails.** Run: `sh godot/tests/run.sh`. Expected: `FAIL tests/test_emitter.gd`.

- [ ] **Step 3: Implement `godot/emitter.gd`,** ported from `Assets/TestEmitter.cs` and the
  readout in `Assets/Editor/TestEmitterEditor.cs`.
  - Outward in station space: `Vector3(sin(a), -cos(a), 0)`. The position along the axis:
    `station.to_local(global_position).z`.
  - Spinward in station space: `Vector3(0, 0, 1).cross(outward) * signf(station.axis.z)`.
  - RANDOM: `Vector2.from_angle(randf() * TAU)` in station XY.
  - Spread offset (Unity's `insideUnitSphere`): a random unit vector times `spread * pow(randf(), 1.0 / 3.0)`.
  - Spawned boxes are added under the station. Set `box.station` before `add_child`. Track
    them in an array and filter with `is_instance_valid`.
  - `info_text()` matches Unity's HelpBox wording, including the `"\nThe spawn point is outside the floor."` line.
  - Update `info_label.text` in `_process`.
  - `toggle_spawn_view()`: if the spawn camera is current, call `clear_current(true)`.
    Otherwise use `look_at_from_position(spawn_point() + axis_dir * size, spawn_point(), spawn_up())`
    and `make_current()`, where `axis_dir` is the station's global +Z and
    `size = max(box_size * 10, spread * 3 if count > 1 else 0)`. The camera sits on the +Z
    side looking along −Z. In Godot's right-handed coordinates that's what puts spinward on
    the right of the screen, as it was in Unity.
  - Trail settings are added in Task 4.

- [ ] **Step 4: Build `godot/main.tscn`:** a `Station` instance with the `Emitter` as its
  child at local `(0, 0, -65.4)`, a `SpawnCamera` (far 35000), a `DirectionalLight3D` with
  shadows off (the cylinder would shadow its own inside), and a `CanvasLayer` panel holding
  the buttons **Spawn**, **Clear spawned** and **Spawn view** (wired to the three emitter
  methods) and a `Label` assigned to `info_label`.

- [ ] **Step 5: Run the tests and check they pass.** Run: `sh godot/tests/run.sh`. Expected: all `PASS`.

- [ ] **Step 6: Manual check.** Run: `godot --path godot`. Press Spawn view, then Spawn with
  `distance_from_axis` set to 3150 in the Remote inspector. Expected: the box falls down the
  screen and drifts left (antispinward). Launch one TOWARD_FLOOR, watch it land, and note
  whether boxes slide smoothly across the 79 m facets. Add that observation to the
  feasibility doc.

- [ ] **Step 7: Commit**

```bash
git add godot docs/godot-port-feasibility.md
git commit -m "Godot port: emitter, in-game spawn panel, spawn view"
```

---

### Task 4: Box trails

**Files:**
- Create: `godot/trail.gd`, `godot/tests/test_trail.gd`
- Modify: `godot/box.tscn` (add a `Trail` child), `godot/emitter.gd` (apply `trail_width`/`trail_time` on spawn)

**Interfaces:**
- Produces: `class_name Trail extends MeshInstance3D` with
  `@export var width := 1.16`, `@export var lifetime := 100.0`, `@export var min_distance := 0.5`,
  `var points: PackedVector3Array`, `var times: PackedFloat64Array`,
  `func add_point(pos: Vector3, now: float) -> void` (skipped if it's within `min_distance`
  of the last point), and `func prune(now: float) -> void` (drops points older than `lifetime`).

- [ ] **Step 1: Write the failing test `godot/tests/test_trail.gd`.** It uses `Trail.new()`
  and doesn't need the scene tree.

```gdscript
	var t := Trail.new(); t.lifetime = 100.0
	t.add_point(Vector3.ZERO, 0.0)
	t.add_point(Vector3(0.1, 0, 0), 1.0)   # too close: skipped
	t.add_point(Vector3(5, 0, 0), 50.0)
	t.add_point(Vector3(10, 0, 0), 101.0)
	check(t.points.size() == 3, "min distance")
	t.prune(101.0)
	check(t.points.size() == 2 and t.points[0] == Vector3(5, 0, 0), "prune")
	t.free()
```

- [ ] **Step 2: Run it and check it fails.** Run: `sh godot/tests/run.sh`. Expected: `FAIL tests/test_trail.gd`.

- [ ] **Step 3: Implement `trail.gd`.**
  - Set `top_level = true` so the trail doesn't move or rotate with the box. Keep an
    accumulated `now` from `_process(delta)` so pausing also pauses the trail.
  - Each frame: `add_point(get_parent().global_position, now)`, then `prune(now)`, then
    rebuild an `ImmediateMesh` as a camera-facing triangle strip. Each point's side vector is
    `tangent.cross(camera_pos - p).normalized() * width / 2`.
  - Material: unshaded `StandardMaterial3D` with `cull_mode = CULL_DISABLED`.
  - The emitter sets `width` and `lifetime` on the box's `Trail` in `spawn()`.

- [ ] **Step 4: Run the tests and check they pass.** Run: `sh godot/tests/run.sh`. Expected: all `PASS`.

- [ ] **Step 5: Manual check.** Run: `godot --path godot`. Spawn several boxes. Expected:
  each leaves a ribbon about 1.16 m wide that fades after 100 s, and Clear spawned removes
  the ribbons too.

- [ ] **Step 6: Commit**

```bash
git add godot
git commit -m "Godot port: ribbon trails for spawned boxes"
```

---

### Task 5: Upright player and third-person camera

**Files:**
- Create: `godot/player.gd`, `godot/player.tscn`, `godot/tests/test_player.gd`
- Modify: `godot/main.tscn` (add the player)

**Interfaces:**
- Consumes: `Station.down_at`, `Station.acceleration_at`.
- Produces: `player.tscn`: a root `CharacterBody3D` (player.gd) with a capsule
  `CollisionShape3D` (radius 0.5, height 2), a `MeshInstance3D`, and a `Camera3D` at local
  `(0, 1.5, 6)` with far 35000 and `current = true`. Exports: `@export var station: Station`,
  `@export var run_speed := 15.0`, `@export var ground_accel := 40.0`,
  `@export var jump_speed := 3.0`, `@export var jump_delay := 1.0`.

- [ ] **Step 1: Write the failing test `godot/tests/test_player.gd`.** For each angle in
  `[0, 90, 180]` degrees, one at a time (free the previous pair first): instantiate `station.tscn` and `player.tscn`, and place the player
  at station-local `Vector3(sin(a), -cos(a), 0) * (station.radius - 2)` with its station set.
  Wait 180 physics frames (3 s) with no input, then:

```gdscript
	var down := station.down_at(player.global_position)
	check(player.is_on_floor(), "on floor at %d°" % deg)
	check(player.global_basis.y.dot(-down) > 0.999, "upright at %d°" % deg)
	check(player.velocity.slide(down).length() < 0.05, "no drift at %d°" % deg)
```

- [ ] **Step 2: Run it and check it fails.** Run: `sh godot/tests/run.sh`. Expected: `FAIL tests/test_player.gd`.

- [ ] **Step 3: Implement `player.gd` `_physics_process(delta)`.** In this order:
  1. Get `down = station.down_at(global_position)`. If it's `Vector3.ZERO`, call
     `move_and_slide()` and return.
  2. Set `up_direction = -down` and `basis = (Basis(Quaternion(basis.y, -down)) * basis).orthonormalized()`.
     This keeps the heading, as Unity's `FromToRotation` did.
  3. `velocity += station.acceleration_at(global_position, velocity) * delta`
  4. If `is_on_floor()`: split `velocity` into its radial part and the part along the floor.
     Move the floor part toward `wish * run_speed` using `move_toward(..., ground_accel * delta)`,
     where `wish` comes from W/S/↑/↓ along `-basis.z` and A/D/←/→ along `basis.x`. Read the
     keys with `Input.is_physical_key_pressed`. Space adds `up_direction * jump_speed`, at
     most once per `jump_delay` seconds.
  5. `move_and_slide()`

  This replaces Unity's log-shaped force curve and physic-material friction, because
  `CharacterBody3D` has neither (see contact-solvers.md). It also fixes a Unity quirk: the
  speed limit there read world-axis `velocity.x`/`.z`. `ground_accel` and `jump_speed` are
  tuning knobs. Unity's 150 N one-step jump only gave about 0.04 m/s, so it didn't really jump.

- [ ] **Step 4: Run the tests and check they pass.** Run: `sh godot/tests/run.sh`. Expected: all `PASS`.

- [ ] **Step 5: Add the player to `main.tscn`** at `(0, -3195, -90.4)` with `station` set.
  Run: `godot --path godot`. Expected: the view starts behind the player standing on the
  floor, WASD walks, Space hops, and Spawn view toggles between the two cameras. Tune
  `ground_accel` by feel.

- [ ] **Step 6: Commit**

```bash
git add godot
git commit -m "Godot port: upright CharacterBody3D player with third-person camera"
```

---

**Skipped:** an editor-time spawn-point gizmo (`@tool` preview, Unity's `OnDrawGizmosSelected`).
The in-game Spawn view covers framing. Add the gizmo if placing the emitter in the editor
gets fiddly. Also skipped: double-precision builds (positions near the 16 km ends are good to
about 2 mm, the same as Unity today).
