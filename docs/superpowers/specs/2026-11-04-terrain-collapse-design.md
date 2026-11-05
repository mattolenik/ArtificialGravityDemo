# Terrain, collapse and pillars: roofs that fall, the surface that sinks, and posts that hold

Design for the second of the three underground projects of ArtificialGravityDemo (Godot 4.7.2, GDScript + GLSL compute on the main RenderingDevice, Jolt), after the tunnels project (`2026-11-03-terrain-tunnels-design.md`, merged 2026-11-04) and before water in the box. The research behind it is `docs/terrain-research.md` section 6.2 (collapse under inadequate support) with the material numbers of 6.4; the code it builds on is the voxel box of the tunnels project: columns with gaps on disk, bricks of 1 m voxels around the player, the sand step (`box_sand.glsl`) with its slope stability and free height, the scoop (`box_edit.glsl`), the pack and unpack, the chunk mesher. The user asked for the research document's rules to be taken as read (2026-11-04), so the parts marked **(call)** are the author's readings of them and of what the tunnels design held for this project; the user decided the intent, the order of the projects, and the free height's role.

Status: design, 2026-11-04, after a builder check (four questions, all settled by the author below: the support search, a pillar's ends, the shells' lips, a pillar left alone). Built 2026-11-05 on `collapse`, with these rulings changing it: the roof-voxel candidate test is any solid rather than a quarter (so a sliver under a fallen roof falls instead of floating); a voxel standing on a pillar counts as a support (a post's cap); the mesher bridges a post's ends into the partial voxels around it; a pillar gap's bounds are its hollow's, and a hollow with bare air beside the post splits into adjacent gaps; with no two air gaps in a row the overflow merge dissolves the lowest pillar instead of inventing dirt; P refuses rock and a hit with solid over it; the pit's rim slivers crumble; the "6 m room keeps a dome" driver check was dropped (a hand-dug roof is two voxel layers); the shovel's level floor is now kept by a scoop only.

## Intent

The user wants a roof that comes down when a room is widened too far, with the surface sinking above it, and posts the player can place to hold a roof up. Today a tunnel holds for ever whatever its width, and a dig under the surface from inside a pit leaves the surface's skin hanging over the hollow as a floating sheet (the shells of 2026-11-04): both are the same missing rule, that a slab of ground over a hollow carries only so wide a span, and falls when asked to carry more. This project adds that rule, the chimney it drives, the sinkhole it ends in, and the pillar that stops it.

## Goals

1. A roof over a hollow fails when its unsupported span exceeds what its material, its thickness and its wetness allow; the failed ground falls into the hollow as loose dirt, with the material's swell, and the sand rule takes it down to the floor.
2. The layer over a failed roof is the new roof and is judged in turn, so a failure climbs as a chimney until the fallen dirt reaches the roof and holds it, or the surface falls in: a sinkhole, the surface sunk by the hollow's height less the bulking.
3. The player places a pillar on a tunnel's floor under its roof, and the pillar counts as a wall for the span: a room too wide to stand holds with a post in its middle. A pillar is never dug, never fails, is saved with the tunnel, and can be taken away.
4. The shells of 2026-11-04 go: a skin half a voxel thick over a 3 m hollow is a roof over too wide a span for its thickness, and falls but for a lip along the hollow's walls. `box_edit.glsl`'s `THIN_ROOF` stays as it is; the span rule is the one rule for thin roofs.
5. Mass is conserved through every failure, to the tenth of a percent the drivers hold, and the surface, the collider and the drawn mesh follow through the paths that exist (the pack, the remesh, the heightfield's hole).
6. The frame cost stays flat: the span is judged only in bricks that are active, and nothing is judged in a tunnel that is quiet.

## Non-goals

- Connectivity: a block of ground cut loose from everything (the research's flood fill from the hull) does not fall unless the span rule reaches it. The flood fill is window-wide; the span rule covers what the shovel makes.
- Beams, props across a tunnel, roofs the player builds: only vertical pillars.
- Rock falling as rigid debris (the research's convex bodies): rock never fails here, as in the cave-in.
- Water in the box, pressure, mud: project 3. Wetness enters only as the column's saturation byte, as it does in the stand slope today.
- Damage, death or a buried player: the player under a fall is stood on the pile by the unbury rule that exists.
- A cost, an inventory or a limit for pillars.
- A finer grid than 1 m voxels; a roof's shape finer than its voxels.

## Anti-goals: what would make this a failure even if it technically works

- A roof that falls in silence or all at once with no warning: the fall is gradual, a voxel losing its solid over about half a second, and the chimney climbs a layer at a time, so the player sees it come.
- A pass over every roof in the box every frame, or any per-voxel loop in GDScript.
- Mass gained or lost in a chimney, a sinkhole or a pillar.
- A tunnel the tunnels design promised that no longer stands: a 3 m tunnel under a roof a voxel thick holds, and a hand-dug pit of five scoops stands to dig it from.
- A pillar the shovel can take, or that is forgotten on save.

## Constraints

- The tunnels design's constraints hold: Godot 4.7.2, GDScript + GLSL compute on the main RenderingDevice, Jolt, no GDExtension; nothing dispatches GPU work or does file I/O inside a readback callback; the slice 1 datum (1 m cells, heights radial from the hull, station-local (θ, z)); window fields and version 3 blobs as they are; the box's step under 0.25 ms per active brick, a remesh under 0.5 ms a chunk, a chunk landing under 2 ms CPU.
- The voxel: solid and loose fractions, a material byte, a compaction byte, a saturation byte, a hanging bit; the column on disk: up to four gaps with a bottom, a top, a loose thickness and a material byte each. The gap material byte is stored today and read by nothing.
- `MaterialSet` holds four rows (dirt, clay, rock, rock face); the box's material table (`box_sand.glsl`'s `Materials` block) and the shaders' colour arrays are sized to four.
- Headless tests cannot create a RenderingDevice; GPU behaviour is proven by drivers through `tests/offscreen.sh` on a copy of the default world, one GPU run at a time.
- The free height (`MaterialSet.roof_span_dry`/`roof_span_saturated`) is the cohesion the tunnels design gave the stand slope: a vertical cut under it stands, a deeper one caves. The research names the same number the material's roof span.

## The parts the user decided

- A roof comes down when a room is widened too far, the surface sinks above it, and pillars hold it up.
- This is the second of the three underground projects; it changes nothing water in the box will have to tear out (the voxel layout and the column form are untouched; a pillar is a gap material).
- The research document's rules are the starting point, taken as read.

## The parts I decided, as my calls

### One number for cohesion: the free height is the roof span **(call)**

The tunnels design made the material's free height the cohesion that lets a roof span at all, and the research gives the same number as the roof span: dirt 4 m dry and 1.5 m saturated, clay 6 and 2, rock 20. This project uses that one number for both and raises dirt's dry value from 4 to 5 m. The reason is the shovel's ball: a hand-dug pit deepens about 1.3 m a scoop, four scoops make 3.05 m and five make 4.33, and a 1.5 m ball cut level from the pit's floor leaves a roof of the pit's depth less 3.05 m. Under a 4 m free height the five-scoop pit caves, so every hand-dug tunnel has a roof of half a metre, which the span rule below cannot let stand over 3 m without also letting the shells stand. Under 5 m the five-scoop pit holds and its tunnel has a roof 1.3 m thick, a voxel and more, which spans 3 m with room to spare. The cave-in's drivers move with it: a pit under 5 m keeps its walls, one over caves. Clay's 6 m and rock's 20 stay; the saturated values stay.

### The span rule **(call)**

A *roof voxel* is a voxel of dirt or clay holding at least a quarter of a voxel of solid, with air under it: the voxel below holds less than a quarter of solid (a sliver a ball's cut leaves is not a floor, and a partial voxel at a roof's underside is itself the roof voxel, not the full voxel over it). Rock, rock face and pillar voxels are never roof voxels: they do not fail. A *support* is a voxel holding at least half a voxel of solid and loose together (a pile that reaches the roof holds it; a dusting does not), or any pillar voxel, in the layer directly under the roof voxel: the hollow's top layer.

The span a roof voxel may carry is the material's roof span, mixed dry to saturated by the column's saturation byte as the stand slope is, times the roof's *thickness factor*: the solid above the roof voxel up to the next air or the surface, in metres, the roof voxel's own solid included, capped at one; a roof a voxel thick or more carries the material's full span, a roof half a voxel thick half of it. Call half that span the *reach*, R.

The rule, per roof voxel, in the disc of radius R around it in the support layer: find the nearest support. None: the voxel fails. One at distance d in some direction: look for a second support within R in the half-disc away from the first (any direction more than a right angle from it). Found: the roof is a beam between two supports and holds. Not found: the roof is a cantilever held from one side, which carries half what a beam does, and the voxel fails unless d is within R / 2. So in dry dirt (span 5 m, R 2.5) a 3 m tunnel under a roof a voxel thick holds everywhere (every roof voxel is within 1.5 m of both walls); a room 6 m across under a voxel or more of roof fails over its middle (farther than 2.5 m from any wall) and, since the voxels next to that middle are held from one side only and farther than 1.25 m from it, on out to 1.25 m of the walls: the roof falls but for a ledge along each wall; a room 6 m across with a post in its middle holds everywhere, every roof voxel being within 2.5 m of the post or a wall with another support across from it, or within 1.25 m of a wall; a 3 m hollow under a half-voxel skin (R 1.25) fails but for a lip 0.6 m wide along its walls: the shells go, and the lips a thin roof leaves at its walls are what a cut edge looks like.

Why the research's nearest support and not a span measured along lines: a post holds a region around it, and four lines through a roof voxel meet a one-cell post only on the post's own row, column and diagonals, so a room with a post in its middle would fall but for a cross. Why the cantilever clause: with the nearest support alone a room too wide loses only the strip in its middle and keeps the rest, a hole and no fall; the clause makes the roof of a room too wide fail together to within a quarter span of its walls, which is what the user asked to see. Why a disc of R and not a distance transform: a roof voxel reads at most the disc, about twenty voxels for dirt, per active brick, far under the step's budget; the jump flood the research names is for a window-wide pass this project does not make. Distances are between voxel centres.

### The failure, the chimney and the sinkhole **(call)**

A failing roof voxel loses `slump_rate` (an eighth) of its solid a step, as the cave-in's wall does: the solid leaves as the step's `out`, and arrives as loose times the material's swell in the voxel's own room and the room of the air voxel under it, the fall rule of the sand step taking it on down from there. About half a second empties a voxel. A voxel whose solid is gone is air; the voxel over it is now a roof voxel over the same hollow, judged by the same rule on the next step, and so the failure climbs. It stops in one of three ways. The hole the fall leaves is narrower than the room by the ledges along the walls, and the layer over it is held by those ledges: a room between the span and the span plus half of it, 5 to 7.5 m in dry dirt, loses its roof and keeps a dome, and only a wider one climbs. The fallen dirt, bulked by the swell, rises in the hollow until it holds at least half a voxel in the layer under the roof, and from then on it is the roof's support: the chimney's own debris props it. Or it reaches the surface: the surface voxel is the last roof voxel, and when it fails the column's top solid run is gone and its surface, packed each step as every active column is, becomes the top of the loose in the hollow, sunk by the hollow's height less the bulking; the tile, the heightfield patch and the chunk mesh follow as they do for any packed column, and a touched chunk whose last gap has filled stays touched until the box moves away, as the tunnels design has it. Nothing new is written to disk: a sinkhole is a column with a shorter run and loose on it.

The wetness: the span uses the column's saturation byte at the roof, mixed as the stand slope is; a wetted roof over a tunnel weakens as the research asks, and project 3's water will drive the byte.

### Where it runs **(call)**

The rule runs in the sand step's flux pass, per active brick, on the roof voxels of that brick's columns, reading its supports through the brick index as the slump reads its neighbours. A brick becomes active when a scoop, a dump, a fall or a failure changes a voxel in it, so the span is judged where something just changed, and a quiet tunnel costs nothing: a room dug before this project stands until something in it moves, which the author accepts. A roof voxel's failure wakes the brick over it as the apply pass wakes the brick across any face a changed voxel lies on, so a chimney crossing bricks keeps climbing. The budget is the step's own, 0.25 ms an active brick.

### Pillars **(call)**

`MaterialSet` gains a fifth row, `pillar`: never dug (the scoop's rule stops at rock, and the pillar's id lies past it), never failing (the span rule skips it, the stand slope skips it, the sand never turns it loose), a swell of 1 and no porosity, drawn in its own colour by the chunk shader and the tile shader (both arrays grow to five). The box's material table grows a row with it.

`P` with the crosshair on a tunnel's floor places one: the hit's column must have air over the hit point and a roof within the dirt span above it; the pillar is the column's air voxels, those holding no solid, from the lowest over the floor (over any loose lying there) up to the highest under the roof voxel, solid, of the pillar material, one cell square. The partial voxels at the floor and at the roof's underside keep their dirt and their material; a pillar's top voxel lies in the roof voxel's support layer, which is what the span rule reads, and a pillar standing on a pile stands on the pile. The ring shows where it will stand. `P` with the crosshair on a pillar takes it away: its voxels become air, and since it held no dirt nothing is lost or gained. Nothing is placed within a cell of the player's own cell, on rock, or where no roof is within reach, and a line is printed as the shovel prints. In a column a pillar is a gap whose material byte is the pillar's id: the pack writes a solid run of pillar voxels between two gaps, or between a floor and a roof, as a gap with that material, and the unpack makes it solid pillar voxels again, so a pillar rides in the window and the blobs with no new field, and a restart draws it where it stood. The far ring and the tiles outside the box never see a pillar, as they never see a gap.

Why a gap material and not a solid run: the column's material at a height follows the strata, and a run's material is clipped against them; a pillar is the one thing in a column whose material is not its stratum's, and the tunnels design kept the byte for it.

#### A pillar left alone **(call)**

A pillar never fails, so one whose floor is dug from under it floats, and the column of ground over a post in a room that has fallen stands on it as a narrow cap (the roof voxel over the post is supported, and its neighbours within a quarter span are held from the post's side); both are the player's own doing, the first undone by taking the pillar away, and neither is refused. In the column a pillar whose floor or roof has gone is one gap among the four a column may hold, and the pack's overflow merge, which turns the solid between the two lowest gaps into loose, never takes a pillar: it merges another pair.

## The player **(call)**

A fall onto the player is a pile landing on their cell: the unbury rule stands them on it, as it stands them on a dump. No clearance rule moves the player away from a collapse. Placing a pillar on or beside the player's cell is refused rather than pushing them out of it.

## Left to the builder

- The axis walks' exact form in `box_sand.glsl` (the reads through the index, the reach, the half-voxel support test on solid plus loose), and how the failure's `out` and arrivals share the cave-in's flux encoding and the voxel below's room.
- The thickness measure: the solid above the roof voxel to the next air, counted in voxels through the index, capped at one.
- The material table's fifth row and the chunk and tile shaders' colour arrays at five; where the pillar's colour comes from (`materials.tres`).
- The pack's recognition of a pillar run as a gap with the pillar's material and the unpack's reverse, and their headless round trip.
- The pillar key's ray rule (the floor hit, the roof search), its place in `Tools`, and the printed refusals.
- The drivers: a `roof` phase in `box_run.tscn` that digs a five-scoop pit and a 3 m tunnel under a roof over a voxel thick and holds it for ten seconds unchanged, then widens the room past 7.5 m and sees the roof fail within ten seconds, the chimney reach the surface, the surface sink over the room by the hollow's height less the bulking, and the loose in the room equal the solid lost times the swell within 0.1 %; a `pillar` phase that places a pillar in the middle of such a room before widening it and sees it hold, takes the pillar away and sees it fall; the `shell` phase asserting, once the box settles, no crumb deeper than a metre inside the hollow (the lips a thin skin keeps along its walls lie nearer its surface than that); the cave phase's depths at the 5 m free height; and the tunnel, play, inside, scroll and restart phases unchanged in what they prove.

## Verification

Headless tests: a column with a pillar gap packs and unpacks bit for bit, through the version 3 blob; the span arithmetic (two-sided, one-sided, the thickness factor, the saturation mix) as a CPU reference against a few hand cases; the material set's fifth row and the table's layout.

Drivers, through `tests/offscreen.sh` on Vulkan, one GPU run at a time: `box_run.tscn` with the `roof`, `pillar` and `shell` phases as above and every existing phase passing; `tool_run.tscn` and `edit_run.tscn` unchanged. The step's GPU time per active brick reported against 0.25 ms with the roof voxels counted.

Acceptance, in the played world: dig a five-scoop pit and a tunnel from it; it holds. Widen it to a room 6 m across; the roof comes down but for a ledge along each wall and the room fills with the fallen dirt. Widen one to 8 m; the fall climbs and the ground above sinks into it. Dig another, place a pillar in its middle before widening; it holds. Take the pillar; it falls. Dig a shallow pit and dig under its rim from inside; no skin hangs over the hollow. Leave, come back, restart: the pillar and the sinkhole are as they were.
