# Terrain, tunnels: the voxel box, and a shovel that digs sideways

Design for the first of three underground projects of ArtificialGravityDemo (Godot 4.7.2, GDScript + GLSL compute on the main RenderingDevice, Jolt). The three were agreed in conversation on 2026-11-03, in this order: **tunnels** (this document), **collapse and pillars**, **water in the box**. This one builds the structure the other two need and changes nothing they would have to tear out. The research behind it is `docs/terrain-research.md` sections 6.1 to 6.5 and 6.8; the code it builds on is the terrain of slices 1 to 3 plus the shovel, lake fill and cave-in of 2026-10-29 (`docs/superpowers/specs/2026-10-24-terrain-slice-1-design.md`, `2026-10-28-terrain-slice-3-design.md`, the plans under `docs/superpowers/plans/`).

Status: design, 2026-11-03, after a builder check (five questions: four settled by the author below, the free height by the user). Decisions marked **(call)** are the author's; everything else was decided in conversation or in the research document.

## Intent

The user wants to dig down with the shovel, then sideways, and walk into a tunnel with the ground above still standing. Today a column of ground holds exactly one solid top, so a tunnel cannot be said. This project gives the ground around the player a true third dimension: a box of voxels in which digging, dumping, piling and walking are all one three-dimensional thing, and from which tunnels get their walls, floors and roofs. The user also asked for the two projects after this one to be real: a roof that comes down when a room is widened too far, with the surface sinking above it, and water that sloshes, jets from a pumped outlet and finds its way through any shape of passage. Those are not built here, but this box is built so that they can be, which is why it is a volume and not a list of spans.

## Goals

1. Dig down, then sideways, with the shovel, and walk into the tunnel; the ground above holds. Dig any surface: floor, wall or roof.
2. The shovel aims where the player looks, up to its reach, and draws a circular patch on whatever surface the crosshair hits; a scoop takes the ball of material under the patch into the hand; a dump puts the held dirt at the patch, on a wall or a roof ending up on the floor below.
3. Loose dirt is one three-dimensional thing: a pile on the surface, rubble on a tunnel floor, dirt dumped off a ledge, all fall when there is nothing under them and slump to repose over their neighbours, with mass conserved as it is today.
4. Tunnel interiors are drawn smooth and collided, and the player walks in them.
5. Everything inside the box survives the window scrolling away and back, a teleport and a restart.
6. The frame cost stays flat: the box simulates and remeshes only where something changed.
7. The structure holds what the next two projects need: a material per voxel, a sparse brick layout that can carry a second, finer field, and stored spans that keep tunnels at any depth.

## Non-goals

- Collapse of tunnels and rooms, the roof-span rule, chimney caving, surface sinking: project 2. Here a tunnel holds for ever.
- Pillars and beams: project 2.
- Water inside the box: streams, flooded tunnels, pressure, jets, sloshing: project 3. Here water keeps slice 3's model on the surface and does not enter tunnels (it pools on a shaft's floor and stops).
- Water carrying loose dirt inside the box (slice 3's transport share): off until project 3, since the box owns the dirt.
- The auger boring sideways. It bores straight down as it does, into the box.
- Finer than 1 m ground voxels, adaptive refinement, a far view of tunnels.
- Loose clay or loose rock: all loose material is dirt, as in slice 3.

## Anti-goals: what would make this a failure even if it technically works

- Two owners of the dirt. Inside the box the voxels are the only truth about ground and loose dirt; the window's fields are written from them, never the other way round while the box holds a column.
- Mass that is not conserved: every scoop, dump, fall, slump, pack and unpack is a volume leaving one place and arriving in one other, checked by the drivers to the tenth of a percent slice 3 holds.
- A seam the player can feel: no step, crack or hole where the box meets the heightfield, and no place where the collider and the drawn surface disagree by more than the drawn mesh's own resolution.
- A per-voxel loop in GDScript on the hot path, or a volume-wide pass every frame.
- A layout the next projects would replace: a voxel with no material, bricks that cannot be addressed by a second field, spans that lose a tunnel on save.

## Constraints

- Godot 4.7.2 standard build, GDScript + GLSL compute on the main RenderingDevice, Jolt; no GDExtension. No image atomics (buffer atomics are fine, the sim uses them). Nothing dispatches GPU work or does file I/O inside a readback callback; `buffer_update` outside open compute lists; async readbacks after `compute_list_end`.
- The slice 1 conventions and datum: 1 m cells, `Δθ = 2π / 16384`, heights radial from the hull, the 512 window of 128-cell tiles, station-local (θ, z) everywhere, everything under `Station`. A cell's area at height h is `(R − h) Δθ` by 1 m, and a volume between two heights is the annulus `Δθ ((R − h1)² − (R − h2)²) / 2`; voxels are wedges of the same kind, one metre tall.
- The slice 2 contracts: window fields are `R32_SFLOAT` metres or `R8_UNORM` bytes; edits are absolute per-cell overrides packed into per-tile blobs by the GPU and re-applied when a tile enters; the collider's issue order stays.
- Budgets: the slice 1 and 3 ones (GPU frame mean under 6 ms at 1440p, hitch under 4 ms, bakes under 1 ms, the simulation under 0.25 ms per active unit per frame), and new: the box's step under 0.25 ms per active brick, a brick's remesh under 0.5 ms, a chunk's collider rebuild under 2 ms CPU, box memory under 32 MB.
- Headless tests cannot create a RenderingDevice; GPU behaviour is proven by drivers run through `tests/offscreen.sh` on a copy of the default world, never on `user://worlds/default`.
- Materials and their numbers come from `godot/terrain/materials.tres`.

## The parts the user decided

- Dig down, then horizontally, and have a tunnel; the ground above holds.
- The shovel is aimable, works on walls as well as the floor, highlights a circular patch where it will dig, and dumps wherever the patch points.
- The underground is true 3D, including the surface and the dirt on it: no 2.5D surface meeting a 3D underground at a seam.
- Sparse voxel bricks, with the density chosen per field, so that water can later be finer than the ground.
- The order of the three projects, and that this one builds the structure the other two need.

## The parts I decided, as my calls

### The stored form: columns with gaps **(call)**

Outside the box, and on disk, ground stays columns. Each column gains up to four gaps, each a bottom and a top height, a loose thickness lying on the floor of each gap, and a material byte per gap (0 for air; project 2 will use it for a pillar, so a pillar has a form on disk from the start): twelve new `R32_SFLOAT` and four new `R8_UNORM` window fields, empty (zero) for every column that has never been tunnelled. The top solid run's top is the `surface` field as today, with `loose` on it; the strata fields (`bedrock_top`, `clay_bottom`, `clay_top`) are height boundaries that a solid run is clipped against, so the material at any height inside a run follows from them. Two known limits of that rule until a project needs more: dirt tamped into solid on a gap's floor inside a clay band comes back as clay after a round trip, and the compaction of loose lying on a gap's floor is not stored (it comes back at 0). The blob grows by the sixteen fields (version 3, 84 bytes per cell, version 2 files loadable). Four gaps is a cap: a fifth stacked tunnel in one column is refused at the dig; a cut makes one gap per column it crosses (a ball's hollow is one vertical interval in a column, merged with a gap it meets), so the cap is reached only by four tunnels stacked in one column.

Why columns and not voxels on disk: unlimited depth, exact heights, and a blob that is tiles of floats, which the save, load, apply and pack paths already handle.

### The box **(call)**

A box of 1 m voxels in cylindrical grid coordinates (θ index, z index, height index), about 256 m square and 64 m tall, following the player in all three axes in steps of one brick, so digging down takes it down with you; its height range runs from 24 m above the player's feet to 40 m below, since tunnels are dug near the player's height and downward. It lives in sparse bricks of 16 × 16 × 16 voxels: a brick pool in a storage buffer and an index table over the box, bricks allocated with a buffer atomic only where there is something (the surface shell, a tunnel, loose dirt), freed when empty. Per voxel: the solid fraction and the loose fraction (16-bit, their sum at most 1: a byte's 4 mm step would cost the conservation checks their tenth of a percent over a few columns, 16 bits is 15 µm; the partial voxel at the top of a column is how a surface at 410.37 m is said), the solid's material, compaction and saturation: 7 bytes a voxel, 28 KB a brick. Memory follows content: a flat area needs a few hundred bricks; a budget of 48 MB holds about 1700.

*Changed 2026-11-04, after the project's review, by the user's choice:* the box is 96 m tall, 24 m above the feet to 72 m below (six bricks up instead of four), and the pool holds a brick per index slot (1536 bricks, 48 MB; the 32 MB line below is set aside). The user wants to dig deeper than 40 m, and the memory is accepted. The same day the shovel's ball went from 1 m to 1.5 m (a scoop of about 9 m³, the ring decal the ball's width): 2 m was asked for first, but a 2 m ball cannot cut a roofed tunnel sideways from a hand-dug pit, since the pit would need 4.5 m of depth for a roof and dirt caves in past the 4 m free height, so tunnels would only descend; 1.5 m keeps a 3 m tunnel under half a metre of roof from a 3.5 m pit. The same day the shovel gained its level cut: a hit on a face steeper than about 40° no lower than a metre under the feet, or on ground rising ahead (from a quarter metre over the feet to head height), lifts the ball onto the level floor (the last wall scoop's while the feet are near it, else half a metre under the feet), so a tunnel dug walking in runs level; the play phase digs by that rule. The same day the surface-nets density became the signed distance along the column to the run's end (from a voxel's fill and its vertical neighbours' two voxels each way; the fill still decides the lateral edges), so a run's ends mesh at their exact heights and a dug slope is flat with one normal instead of a stair of bricks.

Entering the box, a column is unpacked from its window fields into a voxel column over the box's height range; leaving it, the column is packed back: the top of the highest run to `surface`, its loose to `loose`, the gaps and their loose to the gap fields, the strata clamped as the scoop clamps them today. A run is a maximal vertical sequence of voxels holding solid; its top boundary is its top full voxel plus the partial above it, its bottom boundary its bottom full voxel less the partial below it, and a lone partial voxel is a run of its own thickness, so a round trip from voxels to a column and back is exact. A column is packed only when a voxel in it changed, so a column the box never touched keeps its float heights bit for bit. A run that continues past the box's top or bottom keeps its stored boundary there, and the pack merges the held part with the stored remainder. Columns in active bricks are also packed every step they change, so the window's surface and loose are current for everything that still reads them: the surface water, the heightfield collider outside the box's touched chunks, the far ring, the saves. The box is unpacked from resident window tiles only, and the window is twice the box, so a teleport re-centres the box after the window has moved.

Why 1 m voxels: they match the columns one to one, so unpack and pack are exact; the tunnels the shovel digs are two metres across, which the cave-in already made the scale of this terrain. Why 64 m tall: it covers the deepest shovel work around the player while bedrock is 60 to 300 m down on flats and hills, and the box moves with the player, so depth is bounded by the stored columns, not by the box.

### The box owns the dirt **(call)**

Inside the box, every operation on ground or loose dirt runs on voxels; outside it, nothing moves. Slice 3's loose-dirt simulation (the loose half of `sim.glsl`) and the dirt stamps of `edit.glsl` retire rather than run beside the box: one owner of the dirt, and the tools act within metres of the player, so within the box. A pile left mid-slump far from the player freezes until the box reaches it, as a pile beyond the window freezes today; at the box's edge the sand rule refuses to move loose across, as the window's edge refuses flux today, and the dirt parks there. That means the shovel's scoop and dump, the feet's push, the landing's tamp, the auger's cut and its spoil, and the slump all get voxel forms:

- **Scoop:** the ball of radius 1 m at the patch (a 2 m patch; a half ball on a floor is about 2.1 m³ of solid, about 2.6 m³ in the hand with the swell, near today's 2.5). Loose fractions inside the ball go first, then solid fractions by the ball's coverage of each voxel (sampled, so the cut is rounder than the grid), never rock; counted into the hand with the material's swell exactly as today's scoop counts. Held repeats every `scoop_interval`.
- **Dump:** the held volume becomes loose fractions in the air voxels nearest the patch, filling outward from the hit point; the sand rule then lets it fall and slump, so on a wall or a roof it ends up on the floor below. The player is kept clear of the dump as today (the clearance rule in `Tools`, now around the dump point in three dimensions).
- **Push and tamp:** the feet's push moves loose fraction from the top voxels under the footprint to the ones ahead; a landing's tamp raises the compaction of the top loose voxels, and at 1 the loose fraction folds into the solid fraction with the swell, as the 2.5D tamp folds today.
- **The auger:** its tick cuts the shaft's voxels down a step and deposits the spoil as loose voxels at the spoil disc, with the same counters and the same obstacle rule (nothing moves into the shaft while it stands).
- **Sand:** each step, on active bricks only: a loose fraction with air under it falls; the top loose of each column stack slumps to its neighbours' stacks by the slice 3 rule (the excess over the repose line, dry to saturated by the column's saturation, over the eight neighbours, with the annulus volumes), applied per stack so a tunnel floor's rubble and the surface's pile are the same rule. A brick is active while any voxel in it changed more than `move_eps` in the last `settle_time`, the slice 3 bookkeeping lifted to bricks.
- **Slope stability** (the cave-in of 2026-10-29) continues for the surface, as the rule between a column stack's top solid voxel and its disturbed neighbours' stacks. It does not judge tunnel interiors: a tunnel's walls and roof are judged by project 2's roof-span rule, and until then they hold. The rule gains a free height, the material's roof span (`MaterialSet.roof_span_dry` and `roof_span_saturated`: dirt 4 m and 1.5 m, clay 6 and 2 m, mixed by the wall's saturation as the stand slope is; the user's choice of 2026-11-03): a step fails only when it is both steeper than the stand slope and taller than the free height, so a pit under 4 m deep in dry dirt keeps its cut shape, a deeper one caves to the bowl, and a tunnel mouth cut into a pit wall keeps its lintel. It is the same cohesion that lets a roof span at all. The existing drivers' expectations move with it: the pickup phase's 10 m shaft and the edit run's 5.4 m dig still cave, the restart phase's 2.7 m shaft no longer does.

Spilled and pumped water keeps slice 3's model on the window: the sheet flows over `surface + loose` as packed each step, soaks and wets, joins a lake; it does not enter a gap, and its transport of loose is off inside the box. The column's saturation byte is what the sand rule and the surface's cave-in read.

### Drawing and colliding **(call)**

The box is drawn and collided only where it differs from a plain column: a 32 m square *chunk* of the box is *touched* once any column in it holds a gap. Surface-only work (a pile, a pit, a scoop on the ground) is exactly a column, packed each step, and keeps the tile mesh and the heightfield patch; so touched follows from the saved columns alone, and a restart draws the same chunks smooth. Touched chunks are meshed on the GPU by surface nets over the voxel fraction field (solid plus loose; the material per vertex from the voxels), bent onto the cylinder in the meshing pass, and read back per dirty chunk, throttled like the collider's edit bakes; the same arrays become the chunk's `ArrayMesh` and its trimesh collision shape. Tunnels come out with smooth floors, roofs and walls, since the fractions say where inside a voxel the surface lies. Untouched ground inside the box keeps the tile meshes and the heightfield patch as today, and the two meet at a touched chunk's border by the far ring's scheme: the tile mesh steps back from the chunk and the chunk's mesh overlaps it by a cell, the tile sunk a quarter cell under it; the heightfield patch takes NaN samples over touched chunks, which Jolt reads as no ground, so the chunk's trimesh is the ground there, and the hold rule counts a touched chunk as cover. The chunk's shader lights by the light bar exactly as the tiles do, plus a headlamp: a spot light on the player's camera that the chunk and tile shaders treat as an ordinary light, since a tunnel has no sky.

Why surface nets and not column boxes: the user wants smooth tunnels, and the fractions carry the information. Why only touched chunks: the tile meshes and the heightfield collider are measured and fast, and most of the box is plain ground.

### The shovel **(call)**

A ray from the camera along the crosshair, up to `shovel_reach` (raised from 3 m to 4 m so a roof overhead is in reach), against the terrain colliders (the heightfield patch, the edit shape and the chunk trimeshes), gives the hit point and normal. A `Decal` two metres across, a ring, is projected along the normal at the hit while a hit is in reach: that is the patch. `T` scoops the ball there, `Y` dumps there, the HUD line shows the hand as today.

### Persistence and the window **(call)**

The gap fields ride in the window and the blobs; the box packs active columns every step and whole bricks as they leave the box, so the existing settle pack, pack-before-evict, exit pack, autosave and restart paths save tunnels with no new file. The far ring and the tiles outside the box never see gaps (they draw the roof top, which is right from a distance).

## What the next projects need, held here

- **Collapse (project 2):** a material per voxel and the brick layout make the roof test a distance per layer and the chimney a per-column drop; the surface sinking is a pack of the shortened column. The stand slope's free height, below, is the cohesion that lets a roof span at all.
- **Pillars (project 2):** a material id for support, never dug, never failing, counted as a wall; `MaterialSet` grows a row, and the gap material byte is the pillar's stored form.
- **Water (project 3):** a second brick pool at a finer voxel (0.5 or 0.25 m) over the same index table, each water voxel a fill fraction and a velocity, reading the ground's solid fraction at 2:1 or 4:1; particles only for airborne water; lakes and the sea stay still surfaces by the user's fixed-level ruling, counted as sources and sinks. The box's index table, brick allocator and activity bookkeeping are written field-agnostic for that reason.

## Left to the builder

- The exact brick and index layouts, the allocator, and how an active brick list is kept (a flag per brick ORed by the shaders, read back with the stats, as the tiles' flags are).
- The ball's coverage sampling, the dump's fill order, and the sand rule's fall step (whole voxels a step, or a rate).
- The surface-nets variant (plain surface nets with the vertex at the mean crossing is enough; dual contouring is not required), the normal and material per vertex, and the readback's throttle.
- The chunk mesh's shader (the tile shader's material and speckle rules, the light bar include, the headlamp's branch).
- The decal texture and the patch's colour when nothing can be scooped (rock, out of reach).
- Which `EditLayer` modes retire and which stay (the raise for the debug dig and the drivers, the spill, the pack and apply), and the version 3 blob's layout and loader.
- The driver: a `tunnel_run.tscn` on the tool run's world copy that digs a shaft and a sideways tunnel with the shovel, walks the player in, dumps inside, checks the collider under the player and against the drawn mesh, scrolls 600 m away and back, restarts, and sums the box's volume against the hand and the window before and after; and which of `tool_run.tscn`'s dirt phases move to it, port to the box's ops or are retired, keeping every conservation check that still applies.

## The builder check's questions, and the answers

1. A partial voxel in a column: the run rule above (the top partial adds to a run's top, the bottom partial takes from its bottom, a lone partial is its own run), 16-bit fractions, and the dirty-column pack; the round trip is a headless test.
2. Outside the box: nothing moves, the loose simulation and the dirt stamps retire, the edge parks dirt; the box's height range is 24 m up and 40 m down from the feet, a column held only within it.
3. Material per run: a material byte per gap now (for pillars); fill inside a clay band and the compaction of a gap's loose are known limits.
4. The free height: the roof span, the user's choice (the first of three options offered: the roof span, 1 to 2 m, or none).
5. Touched chunks: any column with a gap; derivable from the saved columns.

## Verification

Headless tests: the unpack and pack of a column with gaps round-trip bit for bit, and voxels to a column and back exactly, partial voxels at a run's top, bottom and alone included; a column the box never touched keeps its heights bit for bit; the brick index and allocator on a stub; the version 3 blob loads a version 2 file; the volume of a ball of voxels against the annulus integral; the free height in the cave-in rule's arithmetic; the aim's reach and the patch's placement on a stub collider.

Drivers, through `tests/offscreen.sh` on Vulkan: `tunnel_run.tscn` as above, with the conservation residuals printed and asserted; `tool_run.tscn` with its dirt phases ported, every check that still applies holding; `edit_run.tscn` and the blackout smoke unchanged on a copy of the default world. Budgets reported per pass against the table above, as the existing drivers report theirs.

Acceptance: dig a shaft and a tunnel with the shovel in the played world, walk in, dump a pile inside, walk out; leave and come back; restart; the tunnel, the pile and the surface above are as they were, with no crack, hole or fall-through at the mouth.
