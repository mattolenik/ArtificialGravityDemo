# Terrain approaches for the O'Neill cylinder: research report

Date: 2026-10-24. Produced by a deep-research run (5 search angles, 21 sources fetched, 104 claims extracted, 25 verified by three-vote adversarial checking, 0 refuted). Section 6 was added the same day from design discussion of extended requirements. Two independent adversarial reviews (physics and simulation design; Godot and GPU engineering) were run the same day and their corrections folded in; the reviews are kept as `terrain-research-review-physics.md` and `terrain-research-review-godot.md` beside this file. Each item below carries its verification status:

- **[verified: full text]** checked against the paper or code.
- **[verified: abstract]** only the abstract and metadata could be read (publisher bot-blocked), so body-text numbers are unconfirmed.
- **[lead, unverified]** surfaced by the search phase with a snippet, dropped from verification on budget.
- **[background, unverified]** added by the author from prior knowledge, not checked in this run.

## 1. Requirements restated

1. Procedurally generated terrain with mountain ranges, rivers, valleys, lakes, islands and flatlands.
2. Stretch: the terrain is dynamic and physical. It can be dug up, the dug-up material has physics, mass is conserved and movable, an auger works on both ground and water, and loose material can be flattened and compacted until it merges back into the solid terrain.
3. A combined architecture for a Godot 4.7 project (GDScript, Jolt, compute shaders) where the ground is the inner surface of a cylinder of radius 3200 m and length of tens of km, and "down" is radially outward.

Added after the first report (section 6):

4. Tunnels and overhangs, which collapse when their support is inadequate.
5. Water with mass that interacts physically with terrain and bodies, including waterfalls that are physical and obey the rotating-frame forces (Coriolis).

6. Wet terrain weakens, and water seeps into surrounding terrain under a model of its own.
7. Some materials, such as clay and rock, do not let water seep through.
8. Heterogeneous terrain composition: dirt, clay and rock, each with its own characteristics. Rock does not wet, is stronger and is harder to recompact.

Clarified afterwards: no erosion is wanted, at runtime or as a feature. Solid terrain becomes loose only when a tool, an auger or a collapse loosens it. Water never carves solid ground; it seeps into permeable ground and weakens it, and weakened dirt or clay then fails through the collapse and slope-stability rules. The dynamic requirement is the cycle solid → loose → moved → recompacted → solid.

Decided after the reviews:

9. All water flow in the station is artificial. Rivers are closed loops driven by pump objects that sit inline on a river or move water through a tube, so there is no natural sink. Evaporation exists in principle but is left out until weather is designed.
10. Water wets only a bounded distance into ordinary terrain; the wetted zone saturates and then takes no more. Lakes do not drain through their banks, and banks are not meant to fail on their own.
11. Datum and relief: the default radius is 3200 m, sea level sits 400 m above the hull (the outer 12.5 % of the radius is the base terrain layer, so water can be up to 400 m deep), and mountain height is set by local gravity in generation: a faster-spinning cylinder gets flatter mountains, a slower one taller.

## 2. The geometry first: what the cylinder changes

Every verified method assumes one fixed gravity axis, either a planar heightfield or a global-axis-aligned voxel grid. The cylinder is kinder than a planet here, and this section is the author's own analysis, not a sourced claim.

**The surface is developable.** A cylinder has zero Gaussian curvature, so the hull unrolls isometrically to a flat rectangle parameterised by arc length `s = R·θ` and axial position `z`. A 2.5D heightfield (or a stack of column layers) stored over `(s, z)` with "height" measured as radial depth inward from the hull has gravity exactly normal to the undeformed surface everywhere, just as in the planar case. Planetary terrain tech spends most of its effort on projection distortion (cube-sphere seams, poles, equal-area maps; see Lambers & Kolb 2012 below). None of that applies. The differences from a flat world are:

- a periodic boundary in `s` (circumference ≈ 20.1 km);
- long straight features bend with 1/R when rendered, which the mesh mapping handles for free;
- there is no natural ocean boundary; sinks for drainage (seas, lakes) must be authored or generated;
- the terrain volume on the hull is not developable: at height `h` above the hull the circumferential cell width, the local gravity and a slab's volume all scale by `1 − h/R`.

**Relief and the datum.** Those factors are not small here. The default radius is 3200 m and sea level sits 400 m above the hull, so the base terrain layer is the outer 12.5 % of the radius and seas can be 400 m deep. Measured from the hull:

| level | height above hull | cell-width and gravity factor `1 − h/R` |
|---|---|---|
| hull | 0 | 1.000 |
| sea level | 400 m | 0.875 |
| 500 m above sea level | 900 m | 0.719 |
| 1000 m above sea level | 1400 m | 0.563 |
| 1500 m above sea level | 1900 m | 0.406 |

A terrain column is a wedge, not a box, so heights cannot be the conserved quantity. Store volume (mass) per span on a `(θ, z)` grid and derive each span's radii from its volume; that costs one square root per span and keeps mass exact when material moves between elevations. Slopes use the local metric, `(R − h)·Δθ` across and `Δz` along, and pressure terms use `g(h)`. Gravity is 9.8 m/s² at the hull, as the code has it (decided 2026-10-24), so sea level has 8.6 m/s² and a peak 1 km above it 5.5. Mountain height follows from gravity rather than from a budget (section 3.5). Deep seas raise the shallow-water wave speed to about 60 m/s at 400 m depth, which still fits one 60 Hz step at 2 m cells.

**Coriolis does not deflect rivers.** With Ω along the axis and surface flow velocity `v = v_θ θ̂ + v_z ẑ`, the Coriolis acceleration `−2Ω×v = 2Ω·v_θ·r̂` is purely radial for flow on a level surface. Flow along the axis feels nothing. Flow spinward or antispinward feels heavier or lighter, by `2Ω·v/g ≈ 1.1 % per m/s` (Ω = √(g/R) ≈ 0.055 rad/s, period ≈ 114 s), but is never pushed sideways. Downhill flow has a small radial velocity component and gets a cross-slope push of `2Ω·v·sin α`, about 3 % of the along-slope gravity for 3 m/s on a 30° slope, negligible for routing. So drainage, erosion and shallow-water routing on the surface can ignore Coriolis. It matters only for material with radial velocity: thrown dirt, falling debris, water lifted by an auger. Those already get it from `Station.acceleration_at`. (The run's synthesiser wrote "~0.2 rad/s" and "Coriolis deflection of rivers"; both are wrong for this station.) Falling water is the opposite case: it deflects antispinward by metres to tens of metres. Section 6.5 has the numbers.

**Scale forces tiling.** The surface is roughly 20 km × 30 km ≈ 600 km². Cell counts for the whole surface:

| cell size | cells | 16-bit height only | 4 layers + compaction (≈ 9 B/cell) |
|---|---|---|---|
| 1 m | 603 M | 1.2 GB | 5.4 GB |
| 2 m | 151 M | 302 MB | 1.4 GB |
| 4 m | 38 M | 75 MB | 340 MB |

Storage lives in tiles on CPU or disk; simulation runs only in an active window around the player and tools (1024² cells at 2 m is a 2 km square; Su et al.'s two 1024² scenes take 2.0 to 2.2 ms per step on an RTX 4080, a high-end part). MudRunner, agxTerrain's terrain pager and Chrono's "active domains" all do exactly this.

**Float precision.** Godot's own guidance says single-precision artefacts appear beyond about 4 to 8 km from the origin for a third-person game [verified: full text, Godot docs]. The radius is fixed at 3.2 km, so a floating origin that shifts only along the axis keeps everything within about 3.5 km of the origin without a double-precision engine build. Zechmann & Hlavacs 2025 rebuilt Godot with `precision=double` for their planets; this project should not need to.

**Collision.** Godot's `HeightMapShape3D` is planar. Per tile, use one in the tile's local radial frame. The flat-tile error (sagitta `w²/8R`) is 4 cm for a 32 m tile and 16 cm for 64 m, and because the render mesh is curved by its vertex shader (section 6.8) that error does not vanish: resting objects float or sink by it. Keep tiles at 32 m or below, or build the near-player collider from the same curved points. Seams are a physics problem as well as a geometric one: Jolt's internal-edge removal works within one body, so one body per tile gives ghost contacts at tile borders. Group the near-player tiles into a single heightfield (a 7×7 group is a 113×113 map that Jolt builds in well under a millisecond). The alternative is a trimesh collider rebuilt per edited tile; godot_voxel reports that costs 3 to 5 times the meshing itself and that zero-thickness mesh colliders let fast bodies tunnel [verified: full text], which is the problem the boxes already hit against the hull.

## 3. Procedural generation (requirement 1)

Generation is an offline step: seconds to minutes at world creation is acceptable, so the choice is about control and landform quality, not speed.

### 3.1 Uplift-driven stream-power erosion

- **Cordonnier et al., "Large Scale Terrain Generation from Tectonic Uplift and Fluvial Erosion", CGF 35(2), Eurographics 2016.** [verified: full text] A painted uplift map drives stream-power erosion on a random planar graph; output is a stream graph (elevations, flow directions, rivers, watersheds, ridges) converted to a DEM by blending landform kernels. Lakes are handled explicitly via a super-graph of lakes and passes. Single-threaded C++: 0.03 s/step at 10k nodes, 1.3 s/step at 160k, ~200 steps to converge. Limitations stated by the authors: no sediment deposition (so no alluvial flatlands), one erosion process only. Relevant to the cylinder: the method needs only a sampled graph with neighbours and outflow nodes, not a planar grid, so a periodic graph is straightforward.
- **Schott, Paris, Fournier, Guérin, Galin, "Large-scale Terrain Authoring through Interactive Erosion Simulation", ACM TOG 42(5), SIGGRAPH 2023.** [verified: abstract; code verified] Authoring in the uplift domain with interactive stream-power erosion; copy-paste, warping for folds and faults, point and curve constraints to sculpt ridges and carve rivers. The MIT release at `github.com/H-Schott/StreamPowerErosion` is a single GLSL 4.50 compute shader over a regular heightfield (ping-pong SSBOs, erosion `k·A^0.8·S^2`, local slope-weighted drainage routing, optional hillslope diffusion), with uplift painting only. It clamps border cells to zero elevation as the sea outlet, so a cylinder port must add wrap-around in `s` and a different base-level definition. This is the most directly portable piece of code for Godot's compute pipeline.
- **Tzathas, Gailleton, Steer, Cordonnier, "Physically-based Analytical Erosion for Fast Terrain Generation", CGF 43(2), Eurographics 2024.** [verified: full text] Analytical stream-power solutions make geological time a slider; a multigrid scheme reconciles 2D elevations with the river network. CPU Python+numba: 2048² steady state in 34 s versus 540 s (Steer 2021) and 4800 s (their Python re-implementation of Cordonnier). Code promised at `gitlab.inria.fr/landscapes/analytical-terrains` (not confirmed present). Caveats: linear stream power only, no deposition, valleys can jump when the time slider moves, and the drainage-tree operations are not trivially parallel.
- **Schott, Galin, Guérin, Paris, Peytavie, "Terrain Amplification using Multi-scale Erosion", ACM TOG 43(4), SIGGRAPH 2024.** [verified: abstract] Amplifies a coarse heightfield into a hydrologically consistent fine one by running approximate thermal, stream-power and deposition erosion at several scales with control at each. The published template for "coarse base, physically consistent detail". No code link found.

### 3.2 Water-first generation

- **Fischer, Boeckers, Zachmann, "Procedural Generation of Landscapes with Water Bodies Using Artificial Drainage Basins", CGI 2022.** [verified: full text] Inverts the pipeline: author landmass outlines, generate drainage basins (spanning forest over the grid graph), rivers and lakes first, then grow the heightfield outward from all water bodies with a priority queue so elevation rises monotonically away from water. Rivers, lakes, coastlines, islands, deltas and flatlands come out by construction, with no erosion simulation. Whole pipeline under 25 s at 2048² on a 2018 PC. No public code; realism is qualitative. This fits the cylinder unusually well because there is no natural sea boundary: the designer places the seas (a ring sea around the circumference, or several lakes) and the generator drains everything into them.
- **Génevaux, Galin, Guérin, Peytavie, Beneš, "Terrain Generation Using Procedural Models Based on Hydrology", SIGGRAPH 2013.** [background, unverified] The original rivers-first method, from which Fischer's approach descends.

### 3.3 Learning-based and sketch control

- **Lochner, Gain, Perche, Peytavie, Galin, Guérin, "Interactive Authoring of Terrain using Diffusion Models", CGF 42(7), Pacific Graphics 2023.** [verified: full text] Sketch classes (ridges, drainage, cliffs, flats) plus a 48-d style vector condition a diffusion model; 8 Hz during sketching on an RTX 3090. Output is fixed at 256² ≈ 4.9 km, so a cylinder would need tiling; upscalers go to 2.4 m/px. Code published April 2026 with one model. Follow-ups named but unverified: Terrain Diffusion Network (AAAI 2024), TerraFusion (2025), EarthGen (2024).
- **Guérin et al., "Interactive Example-Based Terrain Authoring with Conditional GANs", SIGGRAPH Asia 2017.** [background, unverified] The cGAN baseline Lochner beats.

### 3.4 Noise-only, for comparison

- **Zechmann & Hlavacs, "Comparative Analysis of Procedural Planet Generators", GAME-ON 2025, arXiv 2510.24764.** [verified: full text] Two Godot planet generators (cube-sphere, quadtree LOD). A 15-person study rated Minecraft-style layered noise (continentalness, erosion, peaks and valleys splines) at 4.13 versus 4.10 for plain FBM, so noise layering bought almost nothing. No erosion, no rivers, no performance figures.

### 3.5 Recommendation for requirement 1

Fischer-style water-first growth for the whole layout. It is the only verified method that guarantees rivers, lakes, islands and flatlands with no erosion simulation at all, and it copes with authored seas. Add noise-based detail at walkable scale. Erosion is not wanted in this project, so the stream-power methods (Schott 2023's shader made periodic, Cordonnier or Tzathas on a periodic graph, Schott 2024 amplification) are listed only as optional offline steps, for the case where mountains ever need more convincing valley and ridge structure than growth plus noise gives.

The generator works on the `(θ, z)` grid against the datum in section 2: sea level is a fixed radius, water bodies may reach 400 m below it, and the maximum relief above it is `H_mtn = H_ref · g_ref / g_sea`, with `g_sea = Ω²·R_sea` the gravity at sea level and `H_ref` a design knob (for example 1200 m at 1 g, which gives 2400 m at half a g and 600 m at two). Growth rates in the Fischer pass scale with `H_mtn`, so spinning the station faster flattens the mountains and spinning it slower raises them. The physical basis is that strength- and cohesion-limited heights scale as `1/g`.

## 4. Dynamic and physical terrain (requirement 2)

### 4.1 The two verified hybrids that do the full loop

**Servin, Berglund, Nystedt, "A multiscale model of terrain dynamics for real-time earthmoving simulation", Adv. Model. Simul. Eng. Sci. 8:11, 2021 (arXiv 2011.00459; the basis of Algoryx agxTerrain).** [verified: full text] The only verified system that already does dig → loose → compact → re-merge with mass conserved:

- Solid ground is a voxel grid (OpenVDB) storing mass, velocity, compaction and occupancy per voxel, with two phases (resting solid, fluidised). The top voxels define a heightfield used for contacts.
- A tool with a cutting edge gets a wedge-shaped "active zone" (Mohr-Coulomb failure wedge, Fundamental Earthmoving Equation). Solid mass inside it becomes nonsmooth-DEM particles, sized to a budget, with leftover mass as fluidised continuum, plus one aggregate rigid body per zone that pushes back on the machine.
- Particles that come to rest outside the zone convert back to solid and raise the heightfield. A cellular automaton does advection, compaction, conversion and angle-of-repose avalanching, conserving total mass to machine precision.
- Compaction: freshly deposited soil gets a loosened compaction `w = 1/S` from a per-soil swell factor (the paper misprints `1/(1+S)`); blunt contact stress compacts voxels by `w = 1 + (1−φc)·Cc·ln(σ/σb)`, clamped, with mass shifted down the column so the surface drops; stiffness, dilatancy and friction angle rise with compaction; the state persists until disturbed.
- Performance: 8 bodies, ~950 particles, 10 PGS iterations, 11 ms per 16.7 ms step on a 2017 i7-7800X, CPU only; 1500× faster than their 50k-particle DEM reference; forces and displacement within 10 to 25 % of it (worse for cohesive and wet soils).
- Limits: fixed gravity along the grid axis (the agxTerrain manual says repose is misrepresented when local Z is not up); the solid phase compacts but does not shear (no deep ruts, no burying); wedge zones need hand-defined cutting edges; the CPU particle step is the bottleneck. No water.

**Su, Zhang, Pan, Aanjaneya, Gao, Wu, "Real-time Height-field Simulation of Sand and Water Mixtures", SIGGRAPH Asia 2023.** [verified: full text] Loose sand and water together with no particles at all:

- Four stacked 2.5D height fields on one grid: static terrain `H`, sand `h_s`, pure water above the sand, mixed water inside the sand.
- Two-layer shallow-water equations for water; Shallow Sand Equations with a depth-integrated Drucker-Prager elastoplastic term (a 2×2 horizontal deformation gradient advected on the grid) and cohesion as a piecewise-linear function of saturation. Dry sand settles to its angle of repose, damp sand holds shape, saturated sand collapses. Mass is conserved by conservative upwinding on a MAC grid.
- CUDA on an RTX 4080, per step: Dam Break 512² 0.46 ms, Seepage 512×1024 3.54 ms, Spring and Flush 1024² 2.16 and 2.04 ms, with 3 sand substeps per water step and simulated time steps of 0.009 to 0.045 s. Over 70 % of the time is deformation-gradient projection (38 to 45 %) plus boundary updates (25 to 39 %).
- Limits: shallow-water assumptions (no overhangs, vertical walls or layered flow); `H` is static, so digging (mass transfer `H → h_s`) and compaction (`h_s → H`) are the project's additions. No code released.

Together these two give the whole requirement in 2.5D: Su et al. for loose material and water on the GPU, Servin et al. for the published form of the dig, swell and compaction rules.

### 4.2 Column-stack erosion with loose-to-solid conversion

- **Nilles, Günther, Wagner, Müller, "3D Real-Time Hydraulic Erosion Simulation using Multi-Layered Heightmaps", VMV 2024.** [lead, unverified; extracted from the full PDF but not voted on] Virtual-pipe shallow water on columns that stack up to 8 layers per cell (bedrock, sand, water each), so horizontal erosion makes overhangs and arches, with a bedrock-support pass that drops unsupported columns. Includes a "petrification" rule that moves a fraction of the sand layer into bedrock each step and merges buried thin columns, a direct published precedent for compaction in a column model. Sand slips at an angle of repose that depends on water depth. CUDA with no CUDA-exclusive features, so portable to Godot compute: ~6 ms/step at 2048² and ~23 ms at 4096² on an RTX 3070. The 6 ms and 23 ms figures are confirmed by the abstract; the memory figure (84 B per column plus 1 B per cell), the support-pass cost and the failure modes below come from the extracted text and were not re-read during review. Code: `github.com/Clocktown/CUDA-3D-Hydraulic-Erosion-Simulation-with-Layered-Stacks`, which now holds the code of the follow-up, Nilles & Müller, "Fast Rendering of Large-Scale Dynamic Multi-Layered Height Maps", VMV 2025 [lead, unverified], written to fix the rendering cost noted below. Failure modes: the support check is a local per-column heuristic the authors call plausible rather than physical (it is not connected-component labelling), caves need a hand-cut shaft, rendering the stacked cuboids is up to 10× slower than the simulation step. This is the upgrade path from a plain heightfield to overhangs and tunnels without leaving the column paradigm. For this project only its data structure, support pass, petrification rule and per-layer water routing matter; its erosion is not wanted.
- **Zhu, He, Li, Wang, Wang, "Shallow Sand Equations: Real-Time Height Field Simulation of Dry Granular Flows", IEEE TVCG 2021.** [lead, unverified] Two-layer granular model (dilute fluid-like, dense solid-like) derived like shallow water; GPU-friendly; one-way coupling to tools via ray casting. Su et al. extend it with cohesion and plasticity.
- **Mei, Decaudin, Hu, PG 2007** (virtual pipes on GPU) and **Šťava, Beneš, Brisbin, Křivánek, SCA 2008** (interactive hydraulic erosion with layered materials). [background, unverified] The lineage Nilles et al. build on.

### 4.3 Heightfield-plus-particles hybrids

- **Holz, Beer, Cuypers, "Soil Deformation Models for Real-Time Simulation: A Hybrid Approach", VRIPHYS 2009** [background, unverified] and **Holz et al., "Real-time simulation of soil deformations using an adaptive hybrid level-set / particle model", ISARC 2013** [lead, unverified]. CM Labs excavation simulators: soil as a heightfield (2009) or 3D level set (2013), with the surcharge cut by a bucket tracked as particles that are reabsorbed when they settle.
- **Leach & Marais, "A GPU-based level of detail system for the real-time simulation and rendering of large-scale granular terrain", WSCG 2014.** [lead, unverified] Heightfield everywhere except near dynamic objects, where cells convert to particles and back, writing changes into the heightfield. Useful for the failure modes at the boundary (mass bookkeeping, popping).
- **Yue, Smith, Chen, Chantharayukhonthorn, Kamrin, Grinspun, "Hybrid Grains", SIGGRAPH Asia 2018.** [background, unverified] Adaptive coupling of DEM grains near contacts with an MPM continuum elsewhere, the research-grade version of Servin's idea.
- **Sumner, O'Brien, Hodgins, "Animating Sand, Mud, and Snow", Graphics Interface 1998 / CGF 1999.** [background, unverified] The classic mass-conserving heightfield footprint model: displaced material is pushed to neighbouring columns and erodes to the angle of repose. Still the simplest published "flatten and squash" rule.

### 4.4 Particle methods (fully 3D loose material)

No MPM, DEM, PBD or SPH source survived verification in this run. Leads and background:

- **Fei et al., "Principles towards Real-Time Simulation of Material Point Method on Modern GPUs", 2021 (arXiv 2111.00699).** [lead, unverified] 1.7 to 8.6× over prior GPU MPM via particle sorting, G2P2G fusion and layout; interactive for hundreds of thousands to low millions of particles.
- **Klár et al., "Drucker-Prager Elastoplasticity for Sand Animation", SIGGRAPH 2016; Tampubolon et al., "Multi-species simulation of porous sand and water mixtures", SIGGRAPH 2017; Gao et al., "GPU Optimization of Material Point Methods", SIGGRAPH Asia 2018; Hu et al., MLS-MPM, SIGGRAPH 2018; Wang et al., multi-GPU MPM, SIGGRAPH 2020.** [background, unverified] The MPM sand and sand-water line. Su et al.'s own comparison used ~500k MPM particles against a 1024² field.
- **Macklin, Müller, Chentanez, Kim, "Unified Particle Physics for Real-Time Applications", SIGGRAPH 2014 (NVIDIA Flex).** [background, unverified] Position-based granular at game rates, no mass or volume guarantees.
- **Chrono::CRM (2025, arXiv 2507.05643).** [lead, unverified] GPU SPH continuum soil in Project Chrono with "active domains" that only simulate near vehicles and tools; the authors report 10 km of terrain and 100 M particles at near-interactive rates on an RTX 4080 Ti / H100, validated on NASA rover and RASSOR digging benchmarks. Project Chrono's older **SCM terrain** (Bekker-Wong pressure-sinkage heightfield with a bulldozing rule that pushes displaced soil to neighbours) is open source and is the simplest terramechanics-grade deformable heightfield to crib from. [background, unverified]

Particles are the right tool for the few seconds a clump is airborne or tumbling out of a bucket. They are the wrong primary representation for a 600 km² world; every system that ships converts particles back into a field as soon as they rest.

### 4.5 Augers

- **IAARC pile-driving paper (continuous-flight auger).** [lead, unverified] States that particle and FE soil models are too expensive for real-time auger simulation and proposes an analytical resistance and conveying model validated against DEM. Offline DEM auger studies (Altair EDEM, lunar-regolith conveying) give conveying rate versus rotation speed. In a column model an auger is a per-frame mass-transfer rule: remove `Δm` from the cells under the flight (ground or water layer), add it at the outlet (as loose sand with swell, or as water), with torque from the analytical resistance. Nothing fancier is needed for play, and because this already gives tool reaction force, it removes the one thing architecture B would add.

### 4.6 Voxel and SDF terrain

- **Zylann/godot_voxel.** [verified: full text and repository, as of 2026-10-24] Actively maintained (last push 2026-10-01, MIT, ~4k stars). Smooth SDF terrain meshed with Transvoxel, LOD stitching, in-game digging with overhangs and tunnels, infinite paging, Godot physics, generator graph with a GPU compute backend (Forward+ only). Usable in official Godot 4.7 as a GDExtension (maintainer confirms; the extension is "lightly tested" and lags the module). Constraints that matter here: SDF stored as 16-bit fixed point by default (±500 units at ~0.015 steps; 8-bit is ±10 at ~0.078), far distances clamped; `VoxelLodTerrain` edits only at LOD0 near the viewer unless `full_load_mode` (memory grows with edited chunks); GPU normalmaps fall back to CPU on edited voxels; collider build 3 to 5× meshing cost; SDF boolean edits conserve nothing, so mass must be bookkept outside the field. A cylinder SDF is trivial in the generator graph (the docs do a planet with `SdfSphere` plus height-projected noise), so the geometry is not the obstacle; the physics of loose material and compaction is.
- **Isosurface choice.** [lead, unverified] A 2019 Blekinge thesis finds Dual Contouring most common in shipped titles (Subnautica, Voxel Farm, No Man's Sky), Transvoxel in Unreal's Voxel Plugin for LOD seams; a 2025 thread reports Transvoxel is hard to make fast, Dual Contouring's QEF solve hinders GPU parallelism and can yield non-manifold meshes, and Voxel Plugin reportedly moved to Surface Nets.
- **Teardown.** [lead, unverified] Dennis Gustafsson: ~half a billion small voxels per level with run-length encoding, physics structures derived at runtime; the newer engine's parallel solver handles large piles of bodies in ~5 ms on a 32-thread i9. Dense small voxels work because levels are a few hundred metres, not kilometres.
- **Deep Rock Galactic, Astroneer, Space Engineers.** [background, unverified] All volumetric (marching-cubes family) with CSG digging and no physical loose material. Astroneer conserves soil at the game-design level: dug soil fills canisters and can be placed back. **Minecraft** moves gravel and sand with a cellular automaton; **Noita** is a 2D falling-sand automaton. **Timberborn** runs a column water simulation over block terrain the player digs, which is the closest game analogue of the recommended water layer.

### 4.7 Cheap visual deformation (what not to confuse with physics)

- **Spintires (Zagrebelnyy, gamedev.net 2013) and MudRunner (80.lv 2017).** [verified: full text; medium confidence, one first-party source each] 16 m blocks, a 25×25 base texture per block, a 128×128 mud-height texture only where mud exists; ruts rasterised into a GPU deformation texture with MIN/MAX blending, explicitly not used for physics; mud forces from a separate Havok phantom volume; simulation only in blocks near the truck; CPU physics and GPU rendering on deliberately separate data. Says nothing about SnowRunner.
- **Batman: Arkham Origins snow, GDC 2014.** [lead, unverified] Actors rendered from below into a displacement map, filtered and accumulated. The render-from-below stamp is the right mechanism for a dig tool to write into a height texture in a compute shader; it just needs the removed volume added to the loose layer to become physical.
- **From Dust, GDC Europe 2010 / SIGGRAPH 2011 talk.** [lead, unverified] Column simulation of water, lava, sand and soil with erosion and sedimentation; deposited sediment becomes walkable terrain and lava solidifies into rock. The canonical shipped layered-column world.

## 5. Combined architectures, ranked

None of the combinations below has been measured by any source; the components have.

### A. All-2.5D column stack on the developed cylinder (recommended)

Grid over `(s, z)`, periodic in `s`, stored in tiles, simulated in an active window on the GPU.

Per cell: solid spans, each with a material (dirt, clay or rock), a compaction value `w` and a volume from which its radial extent is derived; loose soil with material fractions; surface water; and bound pore water as a saturation per span within wetting distance of water (section 6.4). No sediment layer: nothing erodes.

- **Generation:** Fischer-style water-first growth plus noise detail (section 3.5), with erosion passes optional and offline only. Store the result as `H`.
- **Water:** two-layer shallow water or virtual pipes (Su et al.; Nilles et al.). Rivers and lakes are water spans over the generated channels, driven by the pump loops in 6.3: every river is a closed circuit with a pump object, seas and lakes are reservoirs rather than sinks, and a per-loop ledger keeps the mass exact across the window edge. An auger is a pump with a short path. Water never erodes `H`.
- **Loose soil:** shallow-sand with Drucker-Prager and saturation cohesion (Su et al.), so spoil heaps hold a slope, slump when wet and flow under the auger.
- **Digging:** a tool stamp (render-from-below or analytic shape) removes volume from `H` and adds `volume·S` to `h_s` at the tool (swell factor `S` from Servin). Mass is conserved by construction.
- **Compaction and merge:** contact stress from feet, wheels, a tamper or a blade raises `w` via Servin's log law or a simpler density threshold with a settling time; when a cell's `h_s` is below a thickness threshold and its compaction exceeds a bank-density threshold, move it into `H` and reduce the height accordingly (Nilles's petrification is the one-line version).
- **Rendering and collision:** mesh per tile mapped onto the cylinder; per-tile `HeightMapShape3D` in the local radial frame, refreshed when a tile is dirty. Jolt handles the player and dropped objects; the field handles the dirt.
- **Budget evidence:** Su et al. 2.0 to 2.2 ms per step for their 1024² scenes and 3.54 ms for Seepage at 512×1024, about 7 ms scaled to 1024², all on an RTX 4080; Nilles et al. 6 ms per step at 2048² on an RTX 3070 [lead]. Section 6.8 scales these to other GPUs and to per-frame cost. Readback to the CPU must be limited to the cells near the player and tools.
- **Does not do:** overhangs, tunnels, vertical walls, free-falling water. Section 6 extends it with span columns, collapse, pressurised water and parcel waterfalls, and that extended form is the current recommendation.
- **Risk:** low for the dense 2.5D core, where every piece has a published real-time counterpart and the cylinder mapping and `H ↔ h_s` transfer rules are new but small. Medium to high for the section 6 extensions (per-layer water, pressurised spans, pump loops, three-material wetting, parcel waterfalls, connectivity collapse, mixed loose material), none of which has a verified real-time counterpart.

### B. Servin-style voxel-column continuum with Jolt particles

Re-implement the multiscale model on a cylindrical voxel grid (columns along the radius) with Jolt rigid bodies as the active-zone particles and aggregates, plus the shallow-water layer from A.

- **Gains:** rigorous mass conservation, a validated compaction model, real tool reaction forces, visible clumps tumbling out of a bucket.
- **Costs:** CPU-bound at ~1k particles per the paper; the wedge active-zone heuristic has to be rebuilt per tool (an auger is not a blade); the solid phase still does not shear; no published water coupling.
- **Risk:** medium. Its one unique contribution, tool reaction force, is covered by the analytical auger model in 4.5, so B is unnecessary rather than an add-on.

### C. Full 3D SDF terrain with a separate granular layer

godot_voxel (Transvoxel SDF) for tunnels and overhangs, a particle layer (GPU MPM or PBD) for loose material, and a re-merge step that writes settled particles back into the SDF.

- **Gains:** caves, overhangs, arbitrary carving, mature Godot integration.
- **Costs:** no verified system does the particle-to-SDF re-merge with mass conservation; 16-bit SDF quantisation bounds how finely material can be re-merged; LOD0-only edits and memory growth under `full_load_mode`; collider rebuild 3 to 5× meshing and tunnelling through thin colliders; mass must be tracked outside the field; particle gravity must be radial per particle (fine in a compute shader, but every published MPM sand solver assumes one gravity vector).
- **Risk:** high. This is a research project, not a port.

## 6. Extended requirements: tunnels, collapse and physical water

This section is design reasoning built on the verified components above. It was not part of the research run. Items are marked **[design]** for the author's reasoning, **[background, unverified]** for prior knowledge not checked in the run, and **[lead, unverified]** for material the run's search phase surfaced without voting on it.

**The dynamic requirement, as clarified.** No erosion, at runtime or as a feature. The cycle is:

- **Solid.** Part of `H`, with a material and a compaction value per span. Dirt and clay take on water and weaken; rock does not. Solid becomes loose only through the next step.
- **Loosen.** A dig stamp, the auger or a collapse converts a volume of solid into loose material, times the swell factor.
- **Move.** Loose material flows to its repose angle, falls off edges as parcels under the station's force, is carried by the auger, is pushed by blades and wheels, and is optionally pushed by water through one momentum-exchange coefficient that is zero by default.
- **Recompact.** Contact stress or tamping raises compaction. Once a cell's loose layer is thin enough and dense enough, or has settled long enough, it merges back into `H` and is solid again.

Water sits beside this cycle. It has mass, flows, seeps into permeable ground, loads roofs, weakens wet dirt and clay, and pushes bodies. It never converts solid to loose directly; saturated dirt and clay fail through the collapse and slope-stability rules in 6.2.

### 6.1 Representation: span columns

The multi-layer heightfield of Nilles et al., a run-length-encoded voxel column as Teardown uses, and the "height spans" of Onoue & Nishita (Pacific Graphics 2003) are the same data structure. [design; Onoue & Nishita background, unverified] Each `(θ, z)` cell holds a short list of spans, each with material, compaction, saturation and volume; a span's radial extent is derived from its volume and the cell's `Δθ·Δz`, which is what keeps mass exact on a cylinder (section 2). Loose spans carry material fractions instead of one material (section 6.4). A tunnel is a gap between spans. An overhang is a span with air under it. A flooded tunnel is a water span inside a gap. Most columns hold one span, so storage stays close to a heightfield and the whole-station table in section 2 still applies.

Nilles et al. ran this with up to 8 layers per cell, including a local bedrock-support pass, at about 6 ms per step on a 2048² grid on an RTX 3070, with public code. [lead; the timings are confirmed by the abstract, the rest is from extracted text] Their rendering of stacked cuboids was up to 10× slower than the simulation step; their own VMV 2025 follow-up addresses that, and converting the active window's spans to occupancy or an SDF and meshing it with surface nets on the GPU is the alternative. [design]

**Alternatives to cost before fixing the representation.** [design, raised in review]

- A dense 3D occupancy grid over the top tens of metres of the window: 1024² × 32 layers at 1 B is about 34 MB. Connectivity, roof span and per-layer water become plain 3D stencils and the prefix-sum span buffer disappears. The voxel bubble in the table below is this at 200 m; the question is only how far it extends.
- Discrete block layers (Timberborn and Minecraft style integer spans) instead of continuous span heights. Support and flooding tests become exact and cheap; the price is stepped geometry.
- A CPU cellular automaton in a small extension over a 256 to 512 m active region (16k to 65k columns at 2 m, 10 to 20 Hz). This is how Dwarf Fortress, Timberborn and Noita, the doc's own precedents for pressure, column water and collapse, actually run. It has no readback latency, no texture-sharing plumbing, no fixed-point atomics, and it talks to Jolt directly. For a single-player sandbox where tools act within tens of metres it may be the simpler engineering, and it has not been costed against the GPU pipeline in 6.8.

Three nested resolutions:

| level | extent | form | what runs there |
|---|---|---|---|
| tiles | whole station | spans on disk or CPU | nothing; streamed in and out |
| column window | about 2 km square | spans on GPU | shallow water, shallow sand, support checks, parcels |
| voxel bubble | about 200 m square, 50 m deep, 1 m voxels, about 2 M cells | dense occupancy on GPU | dig stamps, 3D support analysis, debris spawning |

The bubble is a decompressed view of the spans, written back when it moves. Nothing lives only in the bubble.

### 6.2 Collapse under inadequate support

Two tests, both standard in shipped games and both heuristics rather than geotechnics. [design]

- **Connectivity.** Flood-fill from the hull, which has infinite strength, through solid, fill and loose spans alike. Loose and partially compacted fill count as support with their own lower strength; if only solid counted, anything resting on a spoil heap or a refilled floor would fall, and that is the normal state after the dig-fill-compact cycle. Anything not connected falls. Connectivity is a global property, so it cannot be recomputed for a dirty region alone (a roof held up only from the next tile would read as detached): run window-wide label propagation with a per-frame iteration budget, or pointer jumping, and accept that a long tunnel's verdict takes many passes. Precedents [background, unverified]: Teardown and Dwarf Fortress drop disconnected material; Noita turns a detached pixel region into a rigid body.
- **Roof span.** Each material gets a maximum unsupported roof span, reduced by the overburden above it, water included. A roof cell fails when its horizontal distance to the nearest wall exceeds half that span. A jump-flood distance transform over the roof mask gives this per frame on the GPU. Precedents [background, unverified]: 7 Days to Die ships a per-block load and glue model; Red Faction: Guerrilla's GeoMod 2 propagated stress through structures.
- **Failure outcome.** Failed soil becomes loose material with the swell factor from Servin et al. and falls through the gap as granular flow. Failed rock becomes a handful of Jolt convex debris bodies that turn loose on landing. Mass is conserved either way. Neighbours lose support in turn, so chain collapses need no extra code.
- **Supports.** Player-placed beams and pillars are voxelised into the support grid as a material with its own strength.
- **Wet ground.** Saturation from the wetting model in 6.4 shrinks cohesion, repose angle, roof span and stable slope for dirt and clay, so digging under a lake brings the roof down with no special case. Only the wetted halo, a few metres into dirt, is affected, so banks are weakened only in their first metres and the generator keeps those within the saturated stable slope; lakes neither drain nor collapse their banks. Rock is unaffected. Cohesion-limited lengths (roof span, the height of a stable vertical cut) scale with `1/g_local`, so the same material spans farther higher up the terrain; friction-limited angles do not change.
- **Slope stability.** A solid face steeper than its material's stable slope at its current saturation fails: the material above the failure line becomes loose and slumps to repose. This is how wet terrain weakens without any erosion. Strength drops, and the collapse rules do the rest.
- **Generated terrain must already pass.** Noise detail, monotone growth and clay lenses will all produce faces steeper than their material allows, and the rules run only inside the window, so without care the first visit to any region is a landslide. The generator enforces each material's saturated stable slope wherever water can reach and the dry slope elsewhere, and every tile is settled under the rules before it first streams in.

Nilles et al. describe their own support check as "at best physically plausible". The same applies here.

### 6.3 Water in spans and pressurised tunnels

- **Flux.** Shallow-water or virtual-pipe flux between vertically overlapping water spans in neighbouring columns, as Nilles et al. route water per layer. [lead, unverified]
- **Pump loops.** All flow in the station is artificial, so every river is a closed circuit: a pump object with an intake cell set, an outlet cell set and a rate `Q`, either sitting inline on the river or joining two points through a tube, plus a channel from outlet back to intake through whatever lakes or sea lie between. Seas and lakes are reservoirs, not sinks. The generator records each loop's `Q` (Fischer's drainage basins give the discharge per reach) and initialises water depth and velocity to the loop's steady state when a tile streams in, so a river is already flowing when the window reaches it. Outside the window water is frozen, so each loop keeps a ledger: water leaving the window along a channel is credited to the loop's reservoir, a channel entering the window is fed from that reservoir at the loop's steady-state discharge, and a pump whose other end lies outside the window draws from or returns to the same ledger. Player-built pumps and tubes are the same object, and the auger is a pump with a short path. Total water is exact by construction. Evaporation is left out until weather is designed. [design, decided after review]
- **Ceiling rule.** When a water span fills its gap, the cell stores further inflow as compressible surplus with a pressure head, and flux uses the full hydrostatic head, so siphons and pressurised tunnels fill and water finds its way into a dig. The surplus is released as surface water when the roof is removed, which is what keeps the mass accounting honest (the alternative, refusing inflow and pushing it back upstream in the same step, is an elliptic solve, not a local rule). The pressure signal travels one cell per step, so a 500 m siphon at 2 m cells responds after about 250 steps and needs damping to avoid oscillation. [design, untested] Game analogues [background, unverified]: Dwarf Fortress's pressure automaton; Timberborn's column water over diggable blocks.
- **Loads.** A water span's weight counts as overburden on the roof below it, and a pressurised span pushes up on the roof above it.
- **Wetting.** Surface water wets the terrain within a bounded distance under the wetting model in 6.4, which feeds the weakening rules in 6.2.
- **No erosion.** Water never converts solid to loose. Whether moving water pushes already-loose material is one momentum-exchange coefficient in Su et al.'s model, zero by default.
- **Bodies.** Buoyancy and drag from the local water span, applied with `apply_central_force` the way the boxes already take air drag. Jolt never sees the water.
- **Auger.** A mass-transfer rule from the cells under the flight to the outlet, for soil or water alike.

### 6.4 Materials and wetting

Requirements 6 to 8. Three solid materials and the loose forms they produce. Values are starting points for tuning; the orders of magnitude come from soil mechanics. [design; values background, unverified]

| property | dirt | clay | rock |
|---|---|---|---|
| takes on water | yes, throughout | a surface skin only, slowly | no |
| wetting distance and rate | a few metres, over minutes (tunable) | a skin of about 0.1 m, slowly | none |
| porosity, water held per unit volume | about 0.4 | about 0.5 in the skin | 0 |
| when wet | cohesion and friction fall; saturated loose dirt flows as mud | plastic and slick; strength falls sharply | unchanged |
| swell factor on loosening | about 1.25 | about 1.35 | about 1.6, as rubble |
| loose form and repose, dry → damp → saturated | soil, about 35° → 40° → 20° | clods, about 40° → 45° → slumps | rubble, about 40° throughout, free-draining |
| roof span of solid, dry → saturated | about 4 m → 1.5 m | about 6 m → 2 m | 20 m or more, constant |
| stable slope of solid, dry → saturated | about 60° → 35° | about 70° → 30° | vertical, constant |
| recompaction | to bank density under moderate contact stress; not while saturated | compacts strongly under load, slowly, needs some moisture | rubble compacts only to packed fill under high stress, never back to bedrock |
| Servin compression index (verified range: 0.001 dense sand to 1 soft clay) | about 0.05 | about 0.5 | rubble about 0.005 |

**Wetting model.** [design; decided after review] Water wets a bounded zone of terrain and then stops; nothing flows through the ground. The verified single-material relative is Su et al.'s mixed water, which also treats water inside sand as a saturation field. The earlier aquifer design (Dupuit–Forchheimer flow, perched water tables, springs) is dropped: at any play-scaled conductivity it drained lakes through their banks, which is not wanted.

- **Wetting front.** Terrain within a material's wetting distance of a water span takes water into its pore space until it reaches an equilibrium saturation profile: full next to the water, tapering to zero at the wetting distance. Saturation relaxes toward that profile at the material's wetting rate. Dirt wets a few metres; clay a skin of about 0.1 m; rock nothing.
- **Finite and two-way.** The water absorbed is drawn from the adjacent water span and is bounded by the pore space inside the halo, a one-time volume. If the water body recedes, the halo relaxes back toward the new equilibrium and the water returns to the body. Mass is exact in both directions.
- **No through-flow.** Pore water is bound. It does not migrate under gravity, does not cross from span to span beyond the halo, and does not leave at a free face. There are no aquifers, no perched water tables, no springs and no tunnels flooding through their walls. Tunnels flood only through openings onto the surface water network or through pressurised spans (6.3). A face cut into the halo may weep a cosmetic film at most.
- **Dug material.** Loose material dug from the halo carries its water as moisture (mud) and keeps it until evaporation exists.
- **Cost.** One relaxation pass over the window plus a jump-flood distance to the nearest water span, recomputed only when water surfaces or terrain change. It is unconditionally stable, because the relaxation is bounded by its equilibrium, and cheaper than a water step.
- **Weakening.** Each span's saturation sets its cohesion, friction, repose angle, roof span and stable slope from the table, with Su et al.'s piecewise-linear cohesion law as the verified form. Saturated loose dirt or clay cannot be compacted; it flows instead.
- **Tunables.** Wetting distance and wetting rate per material, chosen for play rather than derived from conductivities. No rate scaling and no stability limit are needed, and the ordering stays: dirt wets, clay barely, rock not at all.

**Mixed loose material.** [design] A loose span carries dirt, clay and rock fractions. Strength and repose blend by fraction. Permeability follows the clay fraction: above roughly a third clay, the mix seals. Compacted mixed material becomes a solid span of fill with blended properties; its rock fraction stays inert and never counts as bedrock. Servin et al. state that inhomogeneous and mixed soils are unsupported in their model, so this goes beyond the verified evidence.

**Generating the stratigraphy.** [design] The base generator produces one surface; materials come from a few extra fields. Bedrock lies a depth field below the surface, deep under flatlands and valleys and breaking the surface on mountains, so peaks and cliffs are exposed rock. Clay occurs as lenses from thresholded noise. Lakes and rivers no longer need liners to hold water, since wetting is bounded; the generator may still line them with clay or rock where dry, strong banks are wanted. Banks within wetting distance of any water body are generated no steeper than their material's saturated stable slope, so they do not slump when the halo forms. Topsoil dirt is thin on steep slopes and thick on flats. Islands get rock cores.

**Consequences worth designing for.** Lakes keep their water; only a halo a few metres wide around them is wet, and that halo is where banks are weakest, so the generator keeps bank slopes within the saturated limit there. Stopping or breaking a pump empties the river below it into its reservoir, and the loop's ledger shows where the water went. Tunnels stay dry unless surface water finds an opening into them; there are no springs until aquifers are wanted. Digging into the wet halo yields mud, which cannot be compacted until it dries. Rubble drains and never becomes bedrock, so a collapsed rock roof leaves permanent scree. Wet dirt slopes slump to a gentler angle with no erosion step, and cohesion-limited spans grow with height as gravity falls.

### 6.5 Waterfalls as parcels, with Coriolis

Shallow-water spans cannot represent free fall; Su et al. and Nilles et al. both list waterfalls as a limitation. The published fix is to switch representation where water leaves the ground: Chentanez & Müller, "Real-time Simulation of Large Bodies of Water with Small Scale Details", SCA 2010, convert heightfield water into particles at edges and reabsorb them on landing; Chentanez, Müller & Kim, SCA 2014, add a 3D grid near the camera. [background, unverified] Here the particle part is enough:

- **Spawn.** When flux in the span solver would leave a lip, meaning the downstream cell's bed is more than a threshold below the water surface or there is a gap beneath, convert that flux into parcels. Each parcel carries a fixed mass, say 50 kg, and the shallow-water velocity as its initial velocity.
- **Fly.** Integrate each parcel with `Station.acceleration_at` and `Station.drag_force`, the two calls the boxes already make, with a tunable drag area per parcel. Water in free fall breaks up and is drag-limited; without drag a 100 m fall would land at 44 m/s and a 50 kg parcel would carry over 2 kN·s, enough to launch any body in the scene. Centrifugal force, its weakening with height and Coriolis are all included. `test_station.gd` and the feasibility doc pin the force function against the exact inertial-frame solution at 10 m on the real hull; `test_drop_math.gd` checks the same math at a 500 m radius.
- **Land.** On reaching the first span below it in its column, the parcel deposits its mass and momentum into that water span. Mass is conserved end to end and the plunge pool receives a real inflow current, offset antispinward.
- **Interact.** A parcel hitting a Jolt body or the player applies an impulse of its mass times the velocity change. A parcel hitting loose soil wets it and can push it. A parcel hitting solid ground wets what the material can take, and the remainder becomes a surface water span on that cell, so water landing on bare rock under a cliff is not lost. No plunge pool is carved, by the clarified requirement. Plunge-pool inflow at 10 to 20 m/s drives the shallow-water time-step limit at 2 m cells, so landing cells may need sub-stepping.
- **Cost.** A 10 m³/s waterfall at 50 kg per parcel is about 200 spawns per second and under a thousand live parcels for a 100 m fall. It runs in the same compute pass as the spans. Impulses for the few nearby bodies accumulate in a small buffer that is read back each frame. Rendering reads the same parcel buffer through a texture shared between the compute pipeline and a vertex shader: stretched billboards or a sheet mesh across the stream, plus spray spawned at impact. [design]

How far the water deflects, from the exact rotating-frame solution for R = 3200 m and 9.8 m/s² at the floor (Ω ≈ 0.0553 rad/s, period ≈ 114 s). Falling matter lands antispinward of plumb and arrives with an antispinward velocity relative to the floor. This is the drag-free envelope; with drag the times are longer and the impact speeds lower (at a 20 m/s terminal speed the 100 m offset drops from 17 m to about 16 m and the impact speed from 44 to 20 m/s):

| fall height | fall time | lands antispinward by | antispinward speed at impact | angle off plumb |
|---|---|---|---|---|
| 10 m | 1.43 s | 0.5 m | 1.1 m/s | 4.5° |
| 50 m | 3.2 s | 6 m | 5.5 m/s | 10° |
| 100 m | 4.6 s | 17 m | 10.9 m/s | 14° |
| 200 m | 6.7 s | 50 m | 21 m/s | 20° |

The 10 m row matches the Jolt measurement in `test_station.gd` and the feasibility doc (1.432 s exact against 1.433 s measured; 0.529 m exact against 0.520 m measured). The small-angle estimate `offset ≈ Ω·g·t³/3` is about 4 % high at 100 m and 8 % high at 200 m.

### 6.6 Consistency rule

Nothing in the simulation hard-codes a gravity vector; everything that leaves the ground asks the station. That covers dirt thrown by the auger, collapsing debris, spray, and rain if the station ever has weather. A dense object released at 500 m lands about 220 m antispinward. Rain does not: drops reach a terminal speed of about 9 m/s within metres and the drift saturates, so with the station's own drag law rain from 500 m lands about 60 m antispinward at a 7° slant. Still visible, four times smaller.

### 6.7 Effect on the ranking

- Span columns replace the plain heightfield as the base of architecture A. The rest of A is unchanged, but its risk is not: the dense core stays low risk and the extensions are medium to high (see A's risk line).
- Architecture B is unnecessary rather than an add-on, since the analytical auger model gives tool reaction force.
- Three alternatives in 6.1 should be costed before the span-buffer design is fixed: a dense 3D occupancy grid over the top of the window, discrete block layers, and a CPU cellular automaton over a small region.
- Erosion is dropped everywhere at runtime: no sediment layer, no carving by water or waterfalls, no erosion step in the column window. Offline erosion during generation stays optional and off by default.
- Materials and wetting add a material per solid span, three fractions per loose span and one relaxation pass per step. The cost is small; the risk is in tuning, since the verified models cover one material each.
- The optional 3D grid or FLIP solver in the bubble is dropped. Parcels cover free fall, the ceiling rule covers flooded tunnels and siphons, spans cover everything in contact with the ground. Keep FLIP as a later upgrade only for sloshing pools and splash detail.
- godot_voxel drops further down. Its SDF carries no mass, material or occupancy, so collapse and water would need a second representation kept in sync with it.
- A full MPM bubble handling rock fracture, sand and water in one solver remains the maximum-fidelity option and remains research-grade.

### 6.8 Running it in real time on the GPU

[design; corrected after the engineering review] Every field lives on the GPU as textures over the active window, every process is a stencil pass at the rate it needs, and the CPU sees only a small patch around the player and bodies. The window size is the tuning knob: 512² is the baseline on Apple silicon and mid-range cards, 1024² the high-end target. Every API named here exists in Godot 4.7.2 and was checked against the installed class reference; the costs are estimates until measured.

**Data layout**

- **Dense fast path.** Most columns are one solid span plus optional loose and water. Store those as 2D textures over the window. The honest field list is 15 to 25 fields (heights and depths, pore water, material, compaction, saturation, three loose fractions, water and loose velocities or fluxes) and every field written by a stencil pass needs a ping-pong copy, so a 1024² window is 120 to 200 MB, not 20 MB. Memory is not the constraint on any target GPU; bytes touched per pass is, and that is what the cost tables scale with.
- **Sparse slow path.** Columns with tunnels or overhangs get extra spans in a storage buffer indexed by a per-column offset and count, rebuilt by a prefix-sum pass when layers appear or vanish. Kernels loop over extra spans only where the count is non-zero. A dense occupancy grid over the top tens of metres of the window is the alternative to cost (6.1).
- **Window movement through staging textures.** `texture_update` and `texture_get_data` have no region arguments in 4.7.2: they move whole layers, and a whole 1024² 32-bit field is 4 MB each way. Moving the window therefore means `texture_update` into a strip-sized staging texture, then `texture_copy` into the wrapped window texture, and the reverse for the strip leaving. The same staging path serves every patch readback below. These copies are on the per-frame path and must be budgeted. Tiles outside the window stay compressed on the CPU, and the compression runs as a compute pass that emits an opaque blob, so GDScript never loops over cells; a per-cell GDScript loop over one strip would cost tens of milliseconds.
- **Fixed point for mass.** Span volumes and masses as integers, velocities as floats; radii are derived per cell from volume (section 2), so the cylinder's shrinking cell width costs one square root per span. Flux schemes then conserve mass exactly. Pick the unit so the smallest meaningful flux per step is at least one unit, or carry a fractional residual, otherwise thin films and slow wetting truncate to zero and stall. Window-wide mass audits overflow 32 bits and need a hierarchical sum.
- **Atomics through storage buffers.** Parcel deposits and other scatter writes go through `uint` atomics on a storage buffer, then one gather pass adds them into the texture. Image atomics are gated by `SUPPORTS_IMAGE_ATOMIC_32_BIT`, which is false under MoltenVK and true on Metal only for recent OS and GPU families; storage-buffer atomics are core GLSL everywhere.
- **Floating origin and per-tile frames.** A floating origin along the axis keeps everything within about 3.5 km of the origin. Vertex shaders compute the cylinder mapping in each tile's local frame, because `θ = s / R` in float32 at 20 km of arc gives millimetre jitter.

**Solvers and rates**

| process | rate | pass shape | evidence or estimate |
|---|---|---|---|
| shallow water, pipe model, with loose material | 60 Hz, 1 to 2 steps per frame | 2 to 4 stencil passes | Su et al.: 2.0 to 2.2 ms per step at 1024², 3.54 ms for Seepage at 512×1024, RTX 4080; their simulated step is 0.009 to 0.045 s, so 60 Hz needs about 1.4 steps per frame, about 3 ms per frame on that card |
| loose-material plasticity | 60 Hz | Drucker-Prager projection | 38 to 45 % of Su's step; start with repose-angle relaxation instead, and the boundary pass (25 to 39 %) remains |
| parcels | 60 Hz | 1 pass over the particle buffer, storage-buffer atomic deposits, 1 gather | under a thousand live parcels per waterfall |
| wetting | about 6 Hz | one relaxation pass toward the equilibrium profile, plus a jump-flood distance to water when water surfaces change | cheaper than a water step, unconditionally stable |
| compaction and stamps | on contact | small regions from an uploaded op list | negligible |
| roof span | dirty tiles, every few frames | jump-flood distance transform, log₂ N passes | 10 passes at 1024², cheap |
| connectivity | window-wide, budgeted iterations per frame | label propagation or pointer jumping | global property; plain propagation needs O(longest support path) passes, hundreds for a long tunnel; no published figure applies, and Nilles's support pass is a different, local heuristic |

Per-frame cost of the Su-equivalent stack alone, scaled by memory bandwidth since these passes are bandwidth-bound:

| GPU | at 1024² | at 512² |
|---|---|---|
| RTX 4080 | about 3 ms | under 1 ms |
| RTX 4060 or M4 Pro | 5 to 8 ms | 1.5 to 2 ms |
| base M1 to M3 | 15 to 30 ms | 4 to 8 ms |

Parcels, wetting, collapse, the displaced-grid rendering and Godot's own frame come on top, and Godot has no asynchronous compute queue, so simulation time adds linearly to frame time. Collapse arriving a few frames after the cut is acceptable.

**Rendering without CPU meshing**

- **Tiles as static grid meshes.** Each tile is a fixed vertex grid. Its vertex shader samples the solid, loose and water textures through `Texture2DRD`, which wraps the compute texture without a copy, displaces radially and maps onto the cylinder in the tile's local frame. Normals come from texture differences. Coarser grids for far tiles give LOD. Every displaced tile needs a `custom_aabb` covering its full displacement range or it gets culled. Integer textures are read with `texelFetch` through `usampler2D`; confirm that an `R32_UINT` texture binds correctly in a material before relying on it, and fall back to 16-bit pairs rather than float bit-casting.
- **Walls and overhangs.** Vertical faces between neighbouring columns are a second static mesh of skirt quads that the vertex shader stretches between the two columns' heights and collapses to zero area where they match. Smooth tunnel interiors, where wanted, come from a surface-nets pass over the sparse columns only, drawn by a pull-vertex shader that reads positions from a texture by `VERTEX_ID`; the scene renderer has no indirect draw, so the mesh has a fixed maximum vertex count with degenerate triangles for unused slots. Nilles & Müller's VMV 2025 follow-up is the published treatment of rendering layered height maps fast.
- **Parcels and water.** A `MultiMesh` whose vertex shader reads each instance's position from the parcel texture by `INSTANCE_ID`, with `visible_instance_count` and a custom AABB. Water is another displaced grid with a translucent material.

**The CPU boundary**

- **Jolt sees heightfields, grouped.** The near-player region is one `HeightMapShape3D` built from a 7×7 group of tiles (113×113 samples at 2 m cells, which Jolt builds in well under a millisecond), not one body per tile: Jolt's internal-edge removal does not cross bodies, so per-tile bodies snag at seams. Farther tiles are individual heightfields. Non-square maps fall back to mesh shapes, odd sample counts are padded by Jolt, NaN marks a hole; 2 m cells mean scaling the collision shape by (2, 1, 2), which Jolt accepts. Where a tunnel's trimesh collider exists, the heightfield cells it covers are set to NaN, or bodies in the tunnel hit a phantom roof.
- **Collider latency and churn.** The chain is: the GPU writes the field, `texture_copy` to staging, `texture_get_data_async` returns after `frame_queue_size` frames (default 2), `map_data` is set, Jolt applies the new shape at the next physics tick. That is about 50 ms behind the rendered surface at 60 fps and 100 ms at 30 fps, visible during collapses and under a flowing heap. Tiles under flowing material are dirty every frame; refresh the group under the player and each dynamic body every frame and round-robin the rest. Measure the per-group rebuild once rather than assuming it.
- **Resting bodies.** Jolt applies a changed static shape with `DontActivate` and does not wake bodies resting on it. This project only gets away with digging under a resting box because every body applies a force each tick and never sleeps; that is now a dependency to state and keep. Debris that "turns loose on landing" needs an explicit rest test in script, not Jolt's sleep state. Ground rising under a body (deposition, compaction heave) teleports the surface into it and launches it; deposition skips cells under uploaded body footprints, or moves the body with the surface.
- **Readback is small, staged and asynchronous.** A 64×64 patch of a few channels is tens of kilobytes once it has been copied into a staging texture; read directly, a channel is a 4 MB layer. `buffer_get_data_async` and `texture_get_data_async` exist in 4.7.2 and return after `frame_queue_size` frames. If the download staging ring (default 128 MB) is exhausted they stall hard, so an accidental whole-window readback is a hitch, not a slow frame.
- **Uploads are op lists.** Each frame the CPU uploads a few hundred bytes: tool stamps, auger transfers, body footprints with normal force for compaction, and body positions for parcel impulses and buoyancy. One kernel applies them. Impulses come back in a tiny buffer.
- **One simulation loop.** Step the GPU from `_process` with a fixed-step accumulator and a cap on steps per frame, so a slow frame cannot queue extra steps into an already slow GPU frame. Impulses from the readback go into a per-tick accumulator with a timestamp and are applied in `_physics_process`, so they are neither doubled nor dropped when frame and tick rates differ. `frame_queue_size` is the latency knob.

**GDScript orchestrates, GLSL computes**

Dispatching twenty compute passes a frame from GDScript costs well under a millisecond of CPU if uniform sets are created once per ping-pong orientation and push constants are prebuilt; std430 layouts are hand-packed with `encode_*`, a recurring source of silent bugs. Each ping-pong pass needs `compute_list_add_barrier` or its own list, or passes race on some GPUs. Use the main rendering device so textures can be shared, and wrap the RD calls in `call_on_render_thread` so the code survives a switch to multi-threaded rendering (under the default single-threaded model it runs immediately, and ordering comes from the render graph). This needs a RenderingDevice renderer, Forward+ or Mobile; the headless test runner has no rendering device, so the GPU path needs windowed tests. Wire `capture_timestamp` first; RenderDoc works only with the Vulkan driver, and on macOS the Metal driver needs Xcode GPU capture. No C++ is required if tiles stay opaque GPU blobs, and a GDExtension could not reach Jolt anyway, since the module exposes nothing beyond `PhysicsServer3D`.

**Order of work**

The first milestone is larger than three textures. It is: the dense fields with ping-pong and barriers, staging textures for strip upload and patch readback, `Texture2DRD` tile shaders with custom AABBs, the asynchronous readback into a grouped heightfield, the fixed-step loop, and water plus repose-angle loose material. That demonstrates digging, moving and recompacting with the real latencies in place, and its first measurement is of scaling against window size, not of agreement with Su et al. unless the test GPU is a 4080-class part. Then parcels, then wetting and pump loops, then sparse spans with collapse.

Things to refuse: a synchronous whole-window readback each frame, per-cell GDScript loops over tiles, image atomics, one physics body per tile near the player, a single world-sized grid, and Drucker-Prager on every loose cell from day one.

## 7. Open questions

From the run:

1. Is there any published or shipped system that couples an SDF/voxel terrain with a mass-conserving granular layer that re-merges settled material into the SDF, with per-frame costs and failure modes? None appeared, so architecture C rests on unverified components.
2. What particle budgets are achievable for GPU MPM or DEM in Godot 4.7 compute shaders on one desktop GPU, and can those particles couple to Jolt rigid bodies (tools, augers) with acceptable latency?
3. How do stream-power and drainage-basin generators behave on a periodic domain, and does any curved-gravity terrain engine offer a tested pattern for non-planar heightfields?
4. Can Su et al.'s four-field model take a dynamic `H` (digging transfer, Servin compaction) and stay near its 2 ms per step at 1024² (about 7 ms for the seepage case), and what density threshold and settling time make "loose becomes solid" feel right in play?

Project-specific additions:

5. Tile size versus sagitta: pick the tile width where the flat-tile collider error is below the visible mesh resolution (32 m gives 4 cm).
6. Where are the seas? Without an authored sink the drainage generator has nowhere to send water. A ring sea around the circumference is the natural O'Neill choice and also gives islands for free.
7. Axial floating origin: the current scene puts the player 3.2 km from the origin already; a long cylinder needs the origin to follow the player along `z`.

From section 6:

8. Ceiling-pressure water: what damping keeps full spans from oscillating, and does the siphon behaviour hold up when a tunnel has several openings?
9. Collapse tuning: per-material roof spans and overburden scaling that feel right in play, and the cost of incremental connectivity recomputation inside the window after a large edit.
10. Parcel landing: a parcel drifts antispinward across columns as it falls, so finding the first span below it must follow its path, and parcels that strike the side face of an overhang need a rule for where their mass goes.
11. Wetting tunables: the wetting distance and rate per material that read well in play, and whether a cut face into the halo should weep at all.
12. Mud: how dug saturated material behaves in a pile (it slumps to the saturated repose angle and cannot be compacted) and whether it should shed water to an adjacent water span.
13. Mixed loose material: fractions per span against separate spans per material, and what compacted mixed fill should be worth as a roof or a slope.

From the reviews:

14. Pump loops: how a loop's ledger is stored with the tiles, how a player-placed pump joins or splits existing loops, and how the window edge feeds a channel whose reservoir is a sea that is itself partly inside the window.
15. Datum gravity is settled at 9.8 m/s² on the hull. Still open: the value of `H_ref`, the mountain height at 1 g.
16. CPU automaton against GPU pipeline: the small-region CPU alternative in 6.1 has not been costed against 6.8, and for a single-player sandbox it may win.

## 8. Caveats on this evidence

- Section 6 is design reasoning added after the research run. Its game precedents, the Chentanez and Müller papers, the groundwater and infiltration models, and the material property values in 6.4 are background knowledge, not verified in the run. Its deflection numbers are computed from the station's parameters, and only the 10 m row is confirmed by a test in the repository. Two independent reviews on 2026-10-24 found three design holes (no water source, lake liners and bank stability, the relief metric) and a set of number and API corrections; all are folded in, and the reviews are kept beside this file. The pump-loop, bounded-wetting and datum decisions in sections 1, 2, 3.5, 6.3 and 6.4 were made after the reviews and supersede the reviews' own recommended fixes for the water budget and lake drainage.
- The 25 surviving claims span nine sources (seven peer-reviewed papers, one engine repository, one developer article). Large parts of the question have no verified evidence here: MPM, DEM, PBD, SPH and falling-sand methods; Teardown, Deep Rock Galactic, Astroneer and Space Engineers internals; SnowRunner and Farming Simulator; tyre-soil terramechanics; From Dust; GAN terrain synthesis; planetary engines. Section 4 marks every such item as a lead or background.
- Schott 2023 and Schott 2024 were verified from abstracts and metadata only (ACM and HAL bot-blocked); Schott 2023's code was read directly.
- All performance numbers are self-reported on different hardware (2016 Core i7, Xeon E5-2650 v4, i7-7800X CPU only, RTX 2070 under Unity, RTX 3070, RTX 3090, RTX 4080 CUDA) and are not directly comparable. Tzathas et al.'s 4800 s baseline is their own Python re-implementation of Cordonnier, whose C++ converged in under two minutes.
- Servin et al. measure accuracy against their own DEM, not field data, and two authors work for the vendor (Algoryx). Their printed deposited-soil compaction formula is inconsistent with their own definition; use `w = 1/S`.
- The Spintires finding rests on one first-party article about the June 2013 pre-release build; one of its claims passed 2 to 1.
- godot_voxel facts (stars, last push, open crash issue #902 on macOS arm64, maintainer less active as of August 2026) are a snapshot from 2026-10-24.
- The synthesis's geometry and ranking (sections 2 and 5) are inference from verified components. The Coriolis correction in section 2 is the author's, derived from the rotating-frame equations already used in `station.gd`.

## 9. Sources

Verified:

- Cordonnier et al. 2016: https://onlinelibrary.wiley.com/doi/10.1111/cgf.12820 (author PDF: https://www.cs.purdue.edu/homes/bbenes/papers/Cordonier16CGF.pdf)
- Schott et al. 2023: https://dl.acm.org/doi/10.1145/3592787 and https://github.com/H-Schott/StreamPowerErosion
- Tzathas et al. 2024: https://onlinelibrary.wiley.com/doi/abs/10.1111/cgf.15033 and https://gitlab.inria.fr/landscapes/analytical-terrains
- Schott et al. 2024: https://dl.acm.org/doi/10.1145/3658200 and https://hal.science/hal-04565030
- Fischer, Boeckers, Zachmann 2022: https://cgvr.cs.uni-bremen.de/papers/cgi22/CGI22.pdf (technical report: https://cgvr.cs.uni-bremen.de/papers/cgi22/TR.pdf)
- Lochner et al. 2023: https://onlinelibrary.wiley.com/doi/full/10.1111/cgf.14941 and https://github.com/Arches-Team/Interactive-Authoring-of-Terrain-using-Diffusion-Models
- Servin, Berglund, Nystedt 2021: https://amses-journal.springeropen.com/track/pdf/10.1186/s40323-021-00196-3.pdf and https://arxiv.org/abs/2011.00459 and https://www.algoryx.se/papers/terrain/
- Su et al. 2023: https://dl.acm.org/doi/10.1145/3610548.3618159 (open access: https://par.nsf.gov/servlets/purl/10493926, author PDF: https://kuiwuchn.github.io/RTWaterAndSand.pdf)
- Zylann/godot_voxel: https://github.com/Zylann/godot_voxel and https://voxel-tools.readthedocs.io/en/latest/smooth_terrain/
- Spintires 2013: https://gamedev.net/tutorials/programming/general-and-gameplay-programming/rendering-and-simulation-in-an-off-road-driving-game-r3216 ; MudRunner 2017: https://80.lv/articles/breakdown-mud-and-water-of-spintires/
- Godot large world coordinates: https://docs.godotengine.org/en/4.4/tutorials/physics/large_world_coordinates.html
- Lambers & Kolb 2012 (ellipsoidal cube maps): https://diglib.eg.org/handle/10.2312/PE.PG.PG2012short.005-010
- Zechmann & Hlavacs 2025: https://arxiv.org/abs/2510.24764
- cuberact planet (Godot 4, GDScript, chunked LOD): https://github.com/cuberact/godot-cuberact-planet-chunked-lod

Leads (unverified):

- Nilles et al., VMV 2024: https://diglib.eg.org/bitstream/handle/10.2312/vmv20241211/vmv20241211.pdf and https://github.com/Clocktown/CUDA-3D-Hydraulic-Erosion-Simulation-with-Layered-Stacks
- Nilles & Müller, "Fast Rendering of Large-Scale Dynamic Multi-Layered Height Maps", VMV 2025 (the repository above now holds this code)
- Zhu et al., Shallow Sand Equations, TVCG 2021: https://www.physicsbasedanimation.com/2021/01/29/shallow-sand-equations-real-time-height-field-simulation-of-dry-granular-flows/
- Holz et al., ISARC 2013: https://www.iaarc.org/publications/fulltext/isarc2013Paper172.pdf
- Leach & Marais, WSCG 2014 / thesis: https://pubs.cs.uct.ac.za/id/eprint/939/1/Thesis_300DPI.pdf
- Fei et al., GPU MPM 2021: https://arxiv.org/pdf/2111.00699
- Chrono::CRM 2025: https://arxiv.org/abs/2507.05643
- IAARC auger model: https://www.iaarc.org/publications/fulltext/176_Analysis_and_Simulation_of_Pile_Driving_Construction_Equipment.pdf
- From Dust, GDC Europe 2010: https://gdcvault.com/play/1013667/Creating-a-High-Performance-Simulation
- Batman: Arkham Origins snow, GDC 2014: https://gdcvault.com/play/1020379/Deformable-Snow-Rendering-in-Batman
- Teardown interview: https://softwareengineeringdaily.com/2025/01/02/teardown-and-voxel-based-rendering-with-dennis-gustafsson/
- Isosurface algorithms in games (thesis 2019): https://www.diva-portal.org/smash/get/diva2:1333567/FULLTEXT02

Background (named from prior knowledge, not verified in this run):

- Chentanez & Müller, "Real-time Simulation of Large Bodies of Water with Small Scale Details", SCA 2010
- Chentanez & Müller, "Real-Time Eulerian Water Simulation Using a Restricted Tall Cell Grid", SIGGRAPH 2011
- Chentanez, Müller & Kim, "Coupling 3D Eulerian, Heightfield and Particle Methods for Interactive Simulation of Large Scale Liquid Phenomena", SCA 2014
- Onoue & Nishita, "Virtual Sandbox", Pacific Graphics 2003 (height spans)
- Sumner, O'Brien & Hodgins, "Animating Sand, Mud, and Snow", Graphics Interface 1998
- Holz, Beer & Cuypers, "Soil Deformation Models for Real-Time Simulation: A Hybrid Approach", VRIPHYS 2009
- Yue et al., "Hybrid Grains", SIGGRAPH Asia 2018
- Klár et al. 2016, Tampubolon et al. 2017, Gao et al. 2018, Hu et al. 2018, Wang et al. 2020 (MPM sand, sand-water and GPU MPM)
- Macklin et al., "Unified Particle Physics for Real-Time Applications", SIGGRAPH 2014
- Génevaux et al., "Terrain Generation Using Procedural Models Based on Hydrology", SIGGRAPH 2013
- Guérin et al., "Interactive Example-Based Terrain Authoring with Conditional GANs", SIGGRAPH Asia 2017
- Mei, Decaudin & Hu, PG 2007; Šťava et al., SCA 2008 (GPU pipe-model erosion)
- Project Chrono SCM deformable terrain (open source)
- Dupuit–Forchheimer and Boussinesq unconfined groundwater equations; Green–Ampt infiltration; standard hydraulic conductivity ranges and earthwork swell factors (soil mechanics references)
- Lenaerts, Adams & Dutré, "Porous Flow in Particle-Based Fluid Simulations", SIGGRAPH 2008
- Games: Teardown, Dwarf Fortress, Noita, 7 Days to Die, Red Faction: Guerrilla, Timberborn, Astroneer, Deep Rock Galactic, Space Engineers, Minecraft, From Dust
