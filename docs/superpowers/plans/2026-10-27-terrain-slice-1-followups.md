# Terrain slice 1: follow-ups

What the whole-branch review of `terrain-slice-1` (plan: `2026-10-27-terrain-slice-1.md`) left open on purpose, so the next slice's brief can pick it up. Nothing here blocks spawning and moving around.

## Carry into the digging slice's brief

- **R1. Edit deltas before any dig writes to the window.** `TerrainWindow.move_to` regenerates a tile from the macro maps whenever it enters a slot, so an edit is lost the moment its tile leaves the window. The hook exists (`tiles_generated` after `_dispatch`); the delta pass should run in the same compute list. Store deltas as absolute overrides of edited cells, not differences from the detail pass: bitwise GPU determinism of `sin`/`smoothstep` across driver versions is not guaranteed.
- **R2. Drop the noise octaves with wavelength under 2 × cell** (`detail.glsl`, the `if (float(s) < 2.0 * pc.cell) break` loop). The 1 m and 2 m octaves on a 1 m grid are at or past Nyquist and give per-cell white noise (0.38 m on exposed rock). That is both the "rough rock" look and most of the 18 cm collider mismatch at altitude. Tuning; needs the user's eye.
- **R3. The 2.8 ms `map_data` assignment per collider bake** is fine at one bake per 64 m but will not survive per-edit rebakes. Options: a small second `HeightMapShape3D` for the edit zone, rebake throttling, or rebaking only when the edit is inside the patch.
- **R4. The far 8 m window will not show edits** (regenerated from macro). Acceptable beyond 256 m for a while.
- **R5. Pin the fall-through safety net.** `Terrain._hold_body` (hold the ground body while the live patch does not cover it) has no committed test. A headless test can drive `ColliderPatch.covers` and `_hold_body` on a stub; the check that matters is windowed: disable `RenderingServer.render_loop_enabled` for 10 s and assert the body is held and does not fall.
- **R6. `bedrock_top` jumps to the surface on faces over 60°** in the detail pass. A solver reading bedrock gradients must treat that as a material flag, not a stratum.
- **R7. Make `Cyl.theta_of` return strictly inside `[0, TAU)`** before more consumers appear (today every consumer wraps).
- **Topsoil thin on steep slopes** (design 6.1 step 8): the detail pass already exposes rock on faces over 60° and on rims; the macro half (scale D by slope in `MacroGenerator._strata`) is a 3-line tuning change that alters bedrock depth, so do it with the digging slice's tuning pass.
- **`collider_bake.glsl` occupancy:** 257 invocations in 5 workgroups take 0.4 to 1.8 ms from poor occupancy, not arithmetic (over the 1 ms budget in some runs). One invocation per output column, or a two-pass map then max, would bring it under 0.1 ms. Matters once edits rebake.
- **A second collider patch per rigid body** (design §9): while flying, the patch follows the camera, so boxes left near the player fall to the hull. The player itself is held and released correctly.

## Minor defects, left as they are

- Spawn with `count = 1` drops the box 10 m above the viewer, onto the player's head (`emitter.gd`); offset the default point a few metres along the facing.
- GPU setup failure is loud but cascades: `TerrainWindow._setup_rd` returning early makes `texture_rd()` throw in `make_tiles`, `_ready` aborts, the player stays held. A guard after `setup` with one `push_error` would make it one line.
- First-run generation blocks the window for 7 to 8 s with progress only on stdout; `generate` already takes a progress callable, so a coroutine that awaits a frame between stages and shows the stage in the panel is small.
- Cell index of (θ, z) is computed in four places (`terrain.gd` twice, `collider_patch.gd`, `debug_window.gd`); a `WorldParams.cell_of(theta, z)` would hold the posmod and the `+ L/2` once.
- Corrupt or incompatible world files regenerate silently; a `push_warning` when the file exists but fails to load costs one line.
- `test_macro_maps.gd` leaves `user://worlds/test_world` behind.
- Water tiles of a window share one transform and AABB, so the transparent sort ties within a window; no view showed wrong blending (the inside of a cylinder rarely self-occludes). A per-node `sorting_offset` from `tile_offset` would fix it if it shows.
- The bicubic macro ramp runs per field with per-field clamps, so `bedrock_top ≤ surface` between texels is kept only by the existing downstream clamps; the only effect is bare rock where bedrock is already within metres of the surface.
- The `place_tiles` test pins the 1 m window only; the 8 m far window (±1024 wrap, 8 m frame scaling) runs through the same code unpinned.
- Dry land can sit up to 0.65 m below an adjacent river surface on small worlds (0 cells on the default world); a floor at the highest adjacent `water_surface` in `_banks` is one line when a world shows it. Cosmetic: the cell is dry in the window.
- Cliff rims are a staircase in plan view along 32 m cell boundaries; a noise-displaced face position in the detail pass would fix it. Rivers turn with 45° corners.
- Smoke driver (`terrain/smoke.tscn`): exits 0 on `FELL THROUGH`, has no `collider_live` timeout, divides by zero with `--legs=0`.
- The suite's `test_station` output sometimes ends with the tail of an intermittent Jolt `CreateJob` warning; it predates this branch and does not involve terrain.

## Measured limits (M1 Max, Godot 4.7.2)

- Metal returns zero GPU timestamps, so per-pass GPU costs are known only through MoltenVK (`--rendering-driver vulkan`); the frame interval on Metal is pinned at 8.33 ms by V-Sync.
- Detail pass 0.23 ms per tile after the bicubic ramp (budget 2 ms); bake median 0.4 to 0.6 ms, max 0.69 to 1.76 ms across runs (budget 1 ms, accepted untuned); GPU frame mean 4.2 ms at 1440p (budget 6 ms).
- Collider follows the drawn mesh to within 18 cm (p99 8 cm) on rough rock at altitude, where cells are 0.77 m wide against the 1 m grid; boxes rest within 3 cm on flats and 5 cm against the cliff face.
