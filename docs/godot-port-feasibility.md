# Porting to Godot with Jolt Physics

**Verdict:** feasible and low-risk. The physics, which is the hard part, is plain vector
maths that carries over unchanged. Most of the work is in the parts that rely on Unity's
Editor.

Assessed October 2026 against Godot 4.7.2 (standard and .NET builds). Jolt became Godot's
default 3D physics engine for new projects in 4.6 ([release notes][g46]).

See also [contact-solvers.md](contact-solvers.md) for how PhysX and Jolt resolve contacts
differently.

## What carries over almost unchanged

- **The artificial gravity.** The rotating-frame acceleration `−Ω×(Ω×r) − 2Ω×v` and the
  quadratic air drag in `ONeillCylinder` become a `RigidBody3D` applying
  `apply_central_force` each physics step. Godot's built-in gravity zones (`Area3D` with
  point gravity) pull toward a point with inverse-square falloff, so they can't model
  "outward from an axis, growing with distance". The custom force is still the way.
- **The drop test.** `ArtificialGravityTests` is pure maths with a closed-form answer, so it
  ports directly as a headless test.
- **The cylinder.** Godot imports `.blend` files directly through Blender. The mesh is
  already cut so every triangle edge is under 410 m.
- **Units.** Both engines use 1 unit = 1 m with Y up.
- **The scripts.** About 720 lines of C#. Godot's .NET build accepts them with mostly
  mechanical API changes, for example `a.Cross(b)` instead of `Vector3.Cross(a, b)`.

## What needs rework

| Unity piece | Godot equivalent | Effort |
|---|---|---|
| Emitter Inspector buttons that spawn in Play mode | **Biggest change.** Godot runs the game in a separate process, so Inspector buttons (`@export_tool_button`, [added in 4.4][toolbtn]) can't reach the running game. The controls become an in-game debug panel, or editor-to-game messaging through Godot's debugger channel. | Medium |
| `TrailRenderer` (100 s of path history) | No direct equivalent. Godot's particle trails ([GPUParticles3D][gpup]) are for short effects, and [aren't supported in the Compatibility renderer][trails]. Use a small custom ribbon-mesh script or a community addon. | Small–medium |
| "Center Scene view on spawn point" button | No known supported API for moving the 3D editor camera from a script. Selecting a spawn-point marker and using the built-in Focus Selection gets close. | Small, partial |
| Upright player (rigidbody with frozen rotation) | `CharacterBody3D` with `up_direction` set toward the axis each frame. Station forces are added to its velocity by hand. | Small |
| Standard Assets mobile-input wrapper (used only for mouse look) | Godot's built-in `Input` | Trivial |
| `ONeillGrid` material, tiling 1100 × 2200 | `StandardMaterial3D` with the same tiling and emission | Trivial |
| NUnit test | GdUnit4, or a plain assert script run headless | Small |

## Risks and unknowns

- **Handedness.** Unity's coordinates are left-handed and Godot's are right-handed. The
  equations stay consistent on their own, but "spinward" may appear on the opposite side of
  the screen. The drop test catches a sign error, so port it first.
- **Language.** C# is solid on desktop. C# web export still looked
  [experimental][csweb] ([proposal discussion][csweb2]); GDScript avoids that if a web
  build is ever wanted.
- **Unverified Jolt behaviour,** which a prototype would settle:
  - how a resting box behaves when forces keep being applied each step (whether bodies sleep).
    **Measured:** a box at rest on the floor is still awake after 5 s, because the force
    applied every tick keeps it awake.
  - **Measured:** the 10 m drop at 3.2 km, using a real Jolt `RigidBody3D` on the trimesh
    hull, lands after 1.433 s (exact 1.432 s), 0.520 m antispinward (exact 0.529 m).
    It needs `continuous_cd`, the equivalent of Unity's continuous speculative mode.
    Without it, the 0.1 m box moves 0.23 m per tick at landing speed and tunnels through the
    zero-thickness hull.
  - how smoothly things slide across the cylinder's 79 m flat sides
  - precision at the 16 km ends: the same roughly 2 mm limit as Unity unless Godot is built
    in double precision
- **Behaviour will differ slightly anyway.** Godot steps physics at 60 Hz by default
  (Unity: 50 Hz), and Jolt's contact solver differs from PhysX. Godot's own notes warn that
  switching engines changes results ([proposal #12289][jolt-plan]).

## Suggested first step

A small proof-of-concept Godot 4.7 project containing just the cylinder, the gravity and
drag forces, a box spawner, and the 10 m drop test. If the box lands about 1.35 m
antispinward at 500 m radius (or 0.53 m at 3.2 km), the core is proven, and the rest is the
tooling work in the table above.

[g46]: https://godotengine.org/releases/4.6/
[toolbtn]: https://godotforums.org/d/42053-one-click-3d-model-to-2d-sprite-in-godot-44-tutorial
[gpup]: https://docs.godotengine.org/en/4.1/classes/class_gpuparticles3d.html
[trails]: https://forum.godotengine.org/t/cant-setup-gpuparticles3d-trails-they-look-broken-wrong-rendering/105199
[csweb]: https://forum.godotengine.org/t/is-there-an-update-on-exporting-c-projects-to-web/128821
[csweb2]: https://github.com/godotengine/godot-proposals/discussions/13076
[jolt-plan]: https://github.com/godotengine/godot-proposals/issues/12289
