# Terrain slice 3: the auger, loose dirt, tamping and spilled water

Design for the third terrain slice of ArtificialGravityDemo (Godot 4.7.2, GDScript + GLSL compute on the main RenderingDevice, Jolt). Slice 1 gave the O'Neill cylinder generated, walkable terrain; slice 2 made it editable (an edit layer applied by the GPU after the detail pass, per-tile saves, a per-sample collider bake with a 65 × 65 edit heightfield under a hole in the big patch, a strict bake issue order). This slice puts the first real tool on it and gives dug material and spilled water a life of their own. The research behind it is `docs/terrain-research.md` (sections 6.1 to 6.4, 6.8); the code it builds on is described in `docs/superpowers/specs/2026-10-24-terrain-slice-1-design.md` and `docs/superpowers/plans/2026-10-27-terrain-edits-C.md`, and the open items it inherits are in `docs/superpowers/plans/2026-10-27-terrain-edits-followups.md`.

## Intent

The user wants to set an auger down, watch the dirt come out and pile up beside it, and then walk into the pile and push it around. That moment is what this slice is built for. Behind it sit three things the whole terrain project needs and has not had yet: material that is loose and has mass, a way for loose material to become solid terrain again, and water that moves and wets what it touches. Everything here is deliberately the smallest version of each that reads right in the hand.

## Goals

1. An auger the player places and picks up, as a plain cylinder prop, that bores a 2 m hole to 10 m depth through dirt and clay, stops at rock or at depth, and piles the spoil beside itself.
2. Loose dirt as a thing in the world: it has volume, it heaps at an angle of repose, it slumps when disturbed or wet, and it never appears from nowhere or vanishes.
3. Walking into a pile pushes it around; repeated jumping on it tamps it until it is solid terrain again.
4. An auger set down in water pumps water out at its base; the water spreads over the ground, pools in low spots, wets dirt it runs over to a bounded distance, and carries loose dirt with it.
5. All of it survives the window scrolling away and back and a restart, on the edit layer slice 2 built.
6. The frame cost stays flat: a few active tiles of simulation, not the whole window.

## Non-goals

- Tunnels, overhangs and collapse (a later slice; this slice's holes are open pits).
- Waterfalls, pump loops, evaporation, weather.
- Loose clay and loose rock as distinct materials: all spoil is loose dirt in this slice, including what the auger cuts from clay. The solid strata keep their materials.
- The auger as a real machine (sound, animation, power); it is a cylinder.
- Any tool other than the auger, the player's feet and the existing debug dig.
- The 8 m far window simulating or showing anything new (it already does not show edits).

## Anti-goals: what would make this a failure even if it technically works

- Mass that is not conserved: dug volume must equal spoil volume times the swell, tamped volume must return to solid volume, and water that flows out must be water that pools or soaks in; the measurement driver checks the sums.
- A pile the player sinks into, falls through or gets launched by: loose dirt is ground, it is walked on like any other ground, and the collider must follow it closely enough that a box rests on it.
- Piles that never settle: a heap left alone must stop moving within a few seconds and cost nothing after that.
- A frame cost that scales with the window: the simulation runs on active tiles only.
- Losing a pile or a puddle to a scroll, a teleport or a restart.

## Constraints

- Godot 4.7.2 standard build, GDScript + GLSL compute on the main RenderingDevice, Jolt; no GDExtension.
- The slice 1 conventions and datum: 1 m cells, `Δθ = 2π / 16384`, heights radial from the hull, the 512 window of 128-cell tiles, station-local (θ, z) in all terrain code, everything under `Station`.
- The slice 2 contracts: window fields are `R32_SFLOAT` metres or `R8_UNORM` bytes; edits are absolute per-cell overrides packed into per-tile blobs by the GPU and re-applied when a tile enters; nothing dispatches GPU work or does file I/O from inside a readback callback; `buffer_update` outside open compute lists; async readbacks after `compute_list_end`; the collider's issue order (a hole never lands before the shape under it) stays as it is.
- Budgets, from the slice 1 design: detail under 2 ms per tile, collider bakes under 1 ms GPU, GPU frame mean under 6 ms at 1440p, hitch under 4 ms. New: the simulation under 0.25 ms per active tile per frame, at most 16 active tiles, the collider's edit-shape rebake while a pile is active no more than 5 times per second.
- Headless tests cannot create a RenderingDevice; GPU behaviour is proven by short windowed drivers that print numbers and quit (they open a window on the user's screen). The default world under `user://worlds/default` is never regenerated or deleted by a driver.
- Materials and their numbers come from `godot/terrain/materials.tres` (`MaterialSet`): dirt's repose angles dry 35°, damp 40°, saturated 20°; swell 1.25; wetting distance 3 m; rock's wetting distance 0. The design uses them; it does not invent new ones.

## The parts the user decided

- **The auger** is a vertical cylinder, about 2 m across, standing in the ground: a placeholder prop. One key places it a few metres ahead of the player where they are looking; it starts on its own when it touches down; it bores straight down to 10 m, or stops earlier when the bore floor reaches rock; the dirt it removes comes out and lands a little to one side of it; walking up to it and pressing the same key picks it up and leaves the hole.
- **The spoil** is loose dirt: the kind water and physics move. It piles up beside the auger.
- **Walking** over or into a pile pushes it around a bit. **Repeated jumping** on it tamps it down until it is part of the solid terrain again.
- **Water:** if the auger goes into water, water flows out of it and wets the nearby ground.
- **Done** is: set the auger down, watch the dirt pile up, walk into the pile and push it around.

## The parts I decided, as my calls

### Loose dirt is a layer, not particles

Each cell gets a `loose` thickness in metres (a new `R32_SFLOAT` window field) sitting on top of the solid `surface`. The drawn surface, the collider, the shoreline and everything that asks "where is the ground" use `surface + loose`. The existing `compaction` byte holds the loose layer's tamping progress (0 freshly dug, 1 solid) and the existing `saturation` byte holds the wetness of the top of the column, loose or solid. There is no loose material id: all loose material is dirt (non-goal above). A particle representation was considered and rejected for this slice: a layer gives piles, pushing, tamping, wetting and persistence through machinery slice 2 already has, at a cost that does not grow with the amount of dirt.

Loose dirt draws as dirt with a visibly looser look (a darker, rougher shade of the dirt colour, stronger when wet) so a pile reads as a pile and a tamped patch reads as ground.

### Piles slump on the GPU toward the angle of repose

A compute pass runs each frame over the active tiles. For each cell it compares the total height `surface + loose` with its four edge neighbours using the real cell widths (`(R − h)·Δθ` across, 1 m along); where the downhill slope exceeds the repose angle for the cell's wetness (dry, damp, saturated: interpolated from `saturation`), it moves part of the excess loose thickness to the lower neighbour, never more than the source cell holds and never more than a fraction of the excess per step so the pile settles rather than oscillates. Only loose material moves; the solid surface never erodes (the project's standing rule). The pass is mass-conserving by construction: a first dispatch writes each cell's outflows to a flux texture, a second applies inflows and outflows, so no cell is written by two threads. A tile is active while any of its cells moved more than a tiny threshold in the last few frames, or while a tool or water is touching it; a tile that has been still for about a second is packed into its edit blob once and leaves the active set. The builder measures the pass and keeps it under the budget by running it on active tiles only; the design does not prescribe the exact flux formula beyond the properties above.

### The auger bores, measures what it removed, and deposits exactly that

The auger is a `Node3D` with a cylinder mesh and a small static body so the player cannot walk through it. When placed it runs a bore stamp through the edit layer ten times a second: within its 1 m radius it lowers the solid surface by a fixed increment per tick (10 m in about 30 s), cutting the strata with the same `min` chain the slice 2 stamp uses, and stops a cell's cut where `bedrock_top` is reached. The stamp accumulates the volume it actually removed (per-cell cut × cell area) into a small storage buffer read back asynchronously; when a reading lands, the auger deposits that volume times the swell as loose thickness into its spoil area: a disc of about 2 m radius centred about 3 m to one fixed side of the auger (the side is chosen at placement, away from the player). The slump pass then shapes it into a heap. The deposit lags the cut by the readback's few frames; that is fine. When every cell of the bore has reached rock, or the bore floor is 10 m down, the auger stops and says so (a small label or a print is enough). Picking the auger up stops it and removes the prop; the hole and the pile stay.

The auger's prop extends from about 2 m above the original ground to just below the 10 m floor, so it always looks like a cylinder standing in its hole; it does not need to move.

Three rules keep the pile beside the hole instead of in it. First, while the auger stands, its footprint (the bore's cells) is an obstacle to loose dirt and water: the slump and water passes take an obstacle mask and never move material into a masked cell, so the pile cannot pour back down the shaft while you watch it grow. Second, the spoil disc is centred about 7 m (7 cells) from the axis, so a full bore's spoil does not reach the rim on its own: the plan computed the bore's true volume with 1 m cells (a five-cell shaft removes about 53 m³ of ground, 67 m³ loose, a 35° cone with a base radius near 4.5 m), which the 4 m first estimated here would not have cleared. Third, once the auger is picked up the mask goes with it: the hole is open ground, and loose dirt that is pushed to the rim slumps into it, which is the honest outcome and what "leaves the hole" means here. There is one auger at a time: pressing the key while one is placed and you are far from it does nothing but a message. The auger itself is a prop, not terrain: it is not saved across a restart (the hole and the pile are), it pauses while its tiles are out of the window (its stamps are refused there) and resumes when they return, and quitting mid-bore loses at most one tick's un-deposited volume, which the measurement driver excludes from its sums.

### Feet push, landings tamp

Every physics tick while the player is on the floor and moving, if the cells under the player's footprint (a disc of about 0.5 m radius) carry loose dirt, a push stamp moves a small share of it (a few centimetres per tick, less than a tenth of what is there) into the cells ahead in the walking direction; the slump pass takes it from there. So walking into a pile bulldozes it a little and walking over it flattens the top. A landing (the player's body going from airborne to on the floor with a downward speed above a threshold) runs a tamp stamp on the same footprint: it raises `compaction` of the loose cells by a fixed step (about a quarter per landing for dirt, so four jumps tamp a patch). When a cell's compaction reaches 1, the cell's loose thickness is folded into the solid column: `surface` rises by `loose / swell`, the top stratum becomes dirt, `loose` becomes 0, and the cell draws and collides as ground. Wet loose dirt tamps the same (a refinement for later). Nothing here can produce or destroy volume except the swell factor on the way in and out, which is the same number both ways.

### Water is a thin layer that flows, pools, wets and carries

Spilled water is a `water_depth` field (metres of water on top of `surface + loose`, a new `R32_SFLOAT` field), distinct from slice 1's static `water_surface` of rivers and lakes. It flows in the same active-tile pass as the slump: a cell passes water to lower neighbours until the water surfaces level out, with a per-step limit for stability, mass-conserving by the same flux scheme. A river or lake cell (one whose static `water_surface` is above the ground) is a reservoir to the sheet: sheet water flowing into it is absorbed and the pump draws from it, so the lake's level does not change and the conservation sums count reservoirs as sources and sinks. Where water stands on dirt it soaks in: each step a small amount of depth moves into `saturation` of the column until it is saturated, and saturation spreads to neighbouring dirt cells only within the material's wetting distance (3 m for dirt, 0 for rock, the research's bounded wetting), so a puddle wets a patch and stops. Saturation has a volume: a cell holds `porosity × 0.5 m` of water when saturated (0.2 m of depth for dirt), lateral wetting moves water from the puddle into the neighbour rather than creating it, and soaking proceeds in steps the 8-bit `saturation` byte can represent; the water sums are checked to 2 %, looser than dirt's half percent because of that quantisation. Saturation lowers the loose layer's repose angle (a wet pile slumps flatter) and darkens the drawn dirt. Water flowing over loose dirt takes some of it along: a cell with water depth and a downhill water flow moves a share of its loose thickness with the flow, which is the research's "loose material is easily moved by water" and nothing more (no erosion of solid ground). There is no sink in this slice: water that flows out stays as puddles and saturation until a later slice adds evaporation.

An auger set down where there is water (the cell's `water_surface` is above the ground, or standing `water_depth` is present) does not bore: it pumps, lifting water from under it and letting it out at the top of the cylinder onto the spoil side, where it lands as sheet depth (on the order of a cubic metre a second) for as long as it stands there, and the sheet does the rest. The picture is the auger standing in the shallows a few metres from the shore, with water spilling onto the bank; the measurement driver places it there. The water mesh draws `max(water_surface, ground + water_depth)` where either is above the ground, so puddles and sheets show.

### Everything rides on the edit layer and the collider of slice 2

The two new fields join the window's field list and the per-tile edit blob (a new blob version; old `.edit` files of version 1 load with the new fields zero). Stamps (bore, deposit, push, tamp, pump) are modes of the edit shader and go through `EditLayer.stamp`, so they pack their tiles back as today. The slump and water pass writes the window directly and packs a tile once it settles. The collider follows through the existing edit shape and hole: each stamp and each settling step calls the collider's `on_edit` at the place that changed, throttled so the edit shape rebakes at most five times a second while a pile is active, and `rebuild` and the hold rule are untouched. The bore, the spoil and the player's feet all sit within the edit zone's reach, so the big patch rebuilds only when activity moves far, which happens when water carries dirt away; zone moves are limited to one per second, so the worst case is one 2.7 ms hitch per second while that lasts. Per-body collider patches stay deferred. The far window ignores all of it.

### Controls

One key, `E`, places the auger ahead of the player or, within about 3 m of a placed auger, picks it up; with an auger placed and the player far from it, the key does nothing but a message. Walking and jumping are the existing controls. The debug dig on `[` and `]` stays as it is.

### Measurement and proof

A windowed driver extends `edit_run.gd`'s pattern: place the auger on flat dirt, wait for it to finish, and check that the removed volume equals the deposited loose volume divided by the swell to within half a percent, that the pile's steepest slope is at or below the dry repose angle once it has settled, that a box dropped on the pile rests within a few centimetres of its surface, that walking through the pile moves loose volume forward and conserves it, that four landings on a tamped patch fold it into the solid surface with the volume accounted for, that an auger placed on a lake pumps a sheet that pools downhill and raises `saturation` of dirt within 3 m and not of rock, and that a pile and a puddle survive a teleport away and back and a restart. It prints the GPU time of the slump and water pass per active tile, the number of active tiles over time, and the collider rebake rate, and records them in `docs/terrain-research.md` section 6.8 with the budgets.

## Left to the builder

- The exact flux formulas for slumping and water flow (stable, conserving, settling), the activity threshold and the settle time, and whether the two passes are one shader or two.
- How the bore's removed-volume accumulator is read back and matched to deposits (a counter per auger, a few frames of lag).
- The spoil disc's exact geometry and how the side is chosen; whether the bore starts with a small ring of spoil already visible so the first second reads right.
- The footprint stamps' exact sizes, rates and thresholds, exposed as tunable values in one place (a `ToolParams` resource or `WorldParams` fields), and whether tamping depends on wetness in this slice.
- The loose-dirt look in the tile shader.
- The pump's rate, the soak rate and the loose-transport share, exposed as the same kind of tunables.
- The blob layout change and the version bump, keeping version 1 files loadable.
- Which tiles count as active when a stamp touches a tile edge, and how activity is tracked (a per-tile flag on the CPU is fine).
- The collider throttle's placement (likely in `Terrain` where `on_edit` is called).
- How the auger prop is built and placed (a scene with a `MeshInstance3D` and a `StaticBody3D`), and the label or print when it stops.
