# Engineering review: terrain-research.md against Godot 4.7.2 + Jolt + GDScript

> Independent adversarial review of `terrain-research.md`, run 2026-10-24 by a fresh agent that was given the document and the repository but not the author's reasoning. Its findings are folded into the main document; this file is kept as the record.

Scope: feasibility of the Godot-specific claims (sections 2, 5, 6.1, 6.5, 6.8), realism of the performance arithmetic, hidden risks, and whether the staged plan is buildable in GDScript + GLSL.

Evidence base, checked in this order:

- Installed engine: `/opt/homebrew/bin/godot --version` = `4.7.2.stable.official.ed1daf0bf`. Class reference dumped with `--doctool` to `scratchpad/godot-doc/doc/classes/` (signatures and enums only; descriptions are empty in a doctool dump, so descriptions were taken from the 4.7 branch XML on GitHub, which is the same text the online docs are built from).
- Project: `godot/project.godot` sets `physics/3d/physics_engine="Jolt Physics"`, feature tag `"Forward Plus"`, no override of `rendering/renderer/rendering_method` (default `forward_plus`), no override of `rendering/rendering_device/driver` (default `.macos` = `metal`), `rendering/driver/threads/thread_model` default `1` (single-safe), physics 60 Hz default, `max_physics_steps_per_frame` 8.
- Engine source, 4.7 branch: `modules/jolt_physics/shapes/jolt_height_map_shape_3d.cpp`, `modules/jolt_physics/objects/jolt_shaped_object_3d.cpp`, `modules/jolt_physics/shapes/jolt_shape_3d.cpp`, `servers/rendering/rendering_device.cpp`, `drivers/metal/rendering_device_driver_metal.cpp`, `drivers/metal/metal_device_properties.cpp`, `drivers/vulkan/rendering_device_driver_vulkan.cpp`; Jolt `HeightFieldShape.cpp` (jrouwe master).
- Online docs (4.7/stable): compute shader tutorial, spatial shader built-ins, shading language, HeightMapShape3D, Texture2DRD.
- Su et al. 2023 Table 2 from the paper text already in the scratchpad (`dl/su2023.txt`).

Severity: Critical = load-bearing technique does not exist or cannot work; Important = materially harder, slower or riskier than stated; Minor = wording or precision.

---

## Critical

None. Every named API exists in 4.7.2 and the architecture has no step that cannot be built. The problems below are about cost, latency, platform behaviour and two API misdescriptions that each have a cheap workaround.

---

## Important

### I1. 6.8 "Toroidal window ... uploads only the new strip and reads back only the old one" cannot be done with the texture API as written

Claim: window textures are addressed with wrap-around so moving the window uploads/reads back only a strip.

What is wrong: `RenderingDevice.texture_update(texture, layer, data)` has no offset or region; it replaces the whole layer and requires the data to match the full texture size (4.7 XML: "Updates texture data with new data, replacing the previous data in place. The updated texture data must have the same dimensions and format"). `texture_get_data` / `texture_get_data_async(texture, layer, callback)` likewise read the whole layer. Only `buffer_update(buffer, offset, size_bytes, data)` and `buffer_get_data(_async)(buffer, ..., offset_bytes, size_bytes)` take ranges. Since the dense fields must be textures for `Texture2DRD` sampling in the tile vertex shader (Godot material shaders cannot read storage buffers), a strip upload per field would be a full 4 MB upload per 32-bit field per window step, and a strip readback a full 4 MB download, which the RD docs themselves call "prohibitive" for real time.

Fix: keep a small staging texture per field (1024 × k or k × 1024, `CAN_UPDATE | CAN_COPY_FROM | CAN_COPY_TO`), `texture_update` the staging texture, then `texture_copy(from, to, from_pos, to_pos, size, ...)` into the window; reverse for the readback (`texture_copy` region into staging, then `texture_get_data_async` on the staging texture). Or stage through an SSBO with `buffer_update` and a scatter kernel. Either way the doc should describe the staging step, because it is on the per-frame path and sets the per-field upload cost.

### I2. 6.8 "A 64×64 patch of a few channels around the player ... is tens of kilobytes" assumes a region readback that does not exist

Same root cause as I1. `texture_get_data_async` reads a whole layer. A 64×64 patch is 16 KB per 32-bit channel only if you first `texture_copy` the region into a 64×64 texture and read that. Otherwise each channel read is 4 MB per frame at 1024². The staging textures for I1 cover this too; the doc should say so and budget the copies. Also note the async path still stalls ("FLUSH_AND_STALL_ALL" in `rendering_device.cpp` `buffer_get_data_async`) when the download staging ring (`staging_buffer/max_size_mb`, default 128) is exhausted, so a whole-window readback by accident is a hard stall, not a slow frame.

### I3. 6.8 "atomics work for parcel deposits" is platform-dependent if the target is a texture

Claim: fixed-point fields in textures plus atomics for parcel deposits.

Evidence: `RenderingDevice.Features` has `SUPPORTS_IMAGE_ATOMIC_32_BIT` ("Support for 32-bit image atomic operations"), and `TEXTURE_USAGE_STORAGE_ATOMIC_BIT` must be set at creation. The Vulkan driver returns `false` for that feature on macOS/iOS ("MoltenVK has previously had issues with 32-bit atomics on images", `rendering_device_driver_vulkan.cpp` line 7420). The Metal driver returns `supports_native_image_atomics`, which is true only for MSL 3.1 + macOS 14 / iOS 17 + Apple6 GPU family (`metal_device_properties.cpp` lines 153-160); on other combinations `texture_create` with the atomic bit fails with "Atomic operations on textures are not supported on this OS version". There is also an env var kill switch `GODOT_MTL_DISABLE_IMAGE_ATOMICS`. Atomics on `uint` in storage buffers are core GLSL and work everywhere.

Consequence: on the development machine (Apple Silicon, current macOS) `imageAtomicAdd` on an `r32ui` window texture works; on an Intel Mac (Vulkan via MoltenVK) or any older OS it does not. Deposits should go through an SSBO (atomic scatter into a per-cell `uint` deposit buffer, then one gather pass adds it into the texture), or the code must branch on `has_feature(SUPPORTS_IMAGE_ATOMIC_32_BIT)`. The doc should pick one; SSBO is the portable one and costs one extra pass.

### I4. "The published numbers put the whole simulation at a few milliseconds per frame on a mid-range GPU for a 1024² window" (6.8) is extrapolation from a high-end GPU, and from per-step not per-frame figures

What the cited numbers actually are (Su et al. Table 2): 1024² scenes (Spring, Flush) run at 2.16 and 2.04 ms per step; the 3.54 ms figure is Seepage at 512×1024, half the cells; 0.46 ms is Dam Break at 512². Hardware is an RTX 4080 (16 GB, ~717 GB/s, ~49 TFLOPS fp32). That is a high-end card, not mid-range. Nilles et al. is an RTX 3070 (448 GB/s).

Per step vs per frame: Su's time steps are 0.009-0.045 s of simulated time; the 1024² Spring scene uses dt = 0.012 s, so 60 Hz real time needs about 1.4 steps per frame, i.e. ~3 ms per frame on the 4080 for the Su stack alone. Roughly 45 % of that is the Drucker-Prager projection the doc defers and ~30 % is boundary handling, so deferring Drucker-Prager buys at most ~2× here, not an order of magnitude.

Scaling to a mid-range or Apple GPU by memory bandwidth (stencil passes over 100-200 B/cell are bandwidth bound): RTX 4060 (272 GB/s) ≈ 2.6× slower; M4 Pro (273 GB/s) ≈ 2.6×; M2/M3 base (100 GB/s) ≈ 7×; M1 (68 GB/s) ≈ 10×. So the Su-equivalent stack is 5-8 ms per frame on a 4060 / M4 Pro and 15-30 ms on a base M-series. On top of that the doc adds parcels, seepage (amortised), compaction, connectivity, the displaced-grid rendering, plus Godot's own Forward+ frame (several ms at 1440p). Godot has no async compute queue; everything is on the one graphics queue in the same frame, so sim cost adds linearly to frame time.

Correction: state the window size as the tuning knob with 512² as the mid-range baseline (4× cheaper) and 1024² as the high-end target; state that the first measurements will be of scaling, not of absolute agreement with Su et al., unless the test GPU is a 4080-class part.

### I5. 6.8 "At 1024² that is around 20 MB" undercounts the dense window by 5-10×; the real cost is bandwidth, not memory

The seven listed fields (solid top, loose thickness, water depth, pore water, material, compaction, saturation) at 4 B each are 7 × 4 × 1,048,576 = 29.4 MB, or ~20 MB only if several are 16-bit. Omitted: shallow-water velocity or pipe fluxes (2-4 fields), loose-material velocity (2), the three material fractions for loose spans (6.4), the saturation-per-span and any 2×2 deformation gradient if Drucker-Prager returns (4), and ping-pong copies of every field written by a stencil pass (×2). A realistic dense window is 15-25 fields × 4 B × ~2 = 120-200 MB. Memory is a non-issue on any target GPU; the relevant number is bytes touched per pass per frame, which is what I4 scales with. Suggest replacing "around 20 MB" with a field table listing format and ping-pong status, and quoting bytes/cell/pass.

### I6. The collider pipeline (6.8 "Jolt sees heightfields") understates latency and per-frame tile churn near flowing material

Verified mechanics: `HeightMapShape3D.map_data` (PackedFloat32Array) and `update_map_data_from_image(image, min, max)` (FORMAT_RF/RH/R8) exist; setting them calls `JoltHeightMapShape3D::set_data` → `destroy()` → `_shapes_changed()` on each owner body, queued and applied in the next space step via `BodyInterface::SetShape(id, shape, false, EActivation::DontActivate)` (`jolt_shaped_object_3d.cpp` line 314). The Jolt shape is rebuilt lazily (`try_build`). Non-square maps and maps with width < 4 fall back to a double-sided mesh shape; odd sample counts are padded by Jolt itself (`HeightFieldShape.cpp` line 441 rounds `mSampleCount` up to a multiple of the block size), so a 32 m tile at 2 m cells (17×17 samples) builds as a true heightfield. NaN = hole is supported by the Jolt path (translated to `FLT_MAX`). All fine.

What the doc understates:

1. Latency chain: GPU writes field at frame N → `texture_copy` to staging → `texture_get_data_async` callback at frame N + `frame_queue_size` (default 2) → `map_data` set in that callback (render thread; same as main thread under the default thread model) → shape applied at the next physics tick. At 60 fps that is ~50 ms behind the rendered surface; at 30 fps ~100 ms. Fine for slow flows; visible for collapses (the player stands on air for 3-6 ticks) and for a heap flowing under the player.
2. "Refreshed only when dirty and budgeted to a few tiles per frame": near a flowing heap or any water body every tile within the flow is dirty every frame. Tiles within 100 m is ~40 tiles of 32 m. Each rebuild is cheap (an 18×18 Jolt heightfield build plus `SetShape` on one static body: tens of µs in C++, plus a GDScript call), so 40/frame is ~2 ms, not a disaster, but "a few per frame" means the collider under a moving heap lags up to a dozen extra frames. Recommend: refresh the tile under each dynamic body and the player every frame, round-robin the rest, and measure the per-tile cost once rather than assuming.
3. The heightfield Godot builds is double-sided (`with_double_sided(..., true)`), zero thickness. Under a tunnel the dense tile's heightfield is still there as the tunnel's roof from below; the sparse-column trimesh must replace, not add to, the heightfield cells it covers (NaN them out), or bodies in the tunnel collide with a phantom surface.

### I7. Tile seams in physics: enhanced internal edge removal does not cross bodies

Section 2 handles the geometric seam correctly (adjacent flat tangent tiles put their shared border at the same angle and radius; residual mismatch is ~0.1 mm). The physics seam is a different matter: each tile is its own StaticBody3D, so Jolt's `use_enhanced_internal_edge_removal` (on by default for bodies and motion queries in this project's settings) and the `active_edge_threshold` only suppress ghost contacts within one shape. A box or the CharacterBody3D sliding from tile A onto tile B meets B's border edge as an active edge; with a 0.57° crease and float rounding on the shared column, expect occasional snags or small hops at seams, the classic tiled-heightfield ghost collision. This project already found that fast bodies need `continuous_cd` against zero-thickness surfaces. Mitigations: overlap tiles by one cell with identical border heights, or build the near-player tiles as one heightfield (a 7×7 group of tiles as a single 113×113 map; Jolt builds it in well under a millisecond), which also cuts the per-tile churn in I6.

### I8. Jolt will not wake sleeping bodies when a heightfield changes under them; the project only avoids this because its bodies never sleep

`SetShape(..., DontActivate)` is used for static bodies, and Jolt does not activate bodies resting on a changed static shape. In this project every RigidBody3D applies `apply_central_force` every tick (box.gd), which the feasibility doc measured keeps bodies awake indefinitely. So dug-out ground under a resting box works by accident, at the cost that no body ever sleeps (Jolt cost scales with all bodies, always). Rock debris that "turn loose on landing" (6.2) therefore needs an explicit rest test in script (speed below threshold for n ticks) rather than relying on Jolt's sleep state, and if anyone later optimises the per-tick force into a gravity area, the terrain coupling breaks. Worth one sentence in 6.8.

The other direction is unaddressed: ground rising under a body (deposition, compaction heave) teleports the surface into the body; Jolt resolves this with Baumgarte 0.2 per velocity step, so a 0.5 m rise launches the body. Deposition should check the uploaded body footprints and not raise cells under a body, or move bodies kinematically with the surface.

### I9. Physics tick (60 Hz) vs render frame vs sim rate is not pinned down

6.8 lists water, loose material and parcels at 60 Hz, but dispatch happens on the render thread per frame. Options and their failure modes:

- Dispatch from `_physics_process`: at 30 fps two ticks run per frame, so two sim steps are queued into one GPU frame that is already too slow, a feedback spiral; at 144 fps most frames have no step and readbacks alias. Needs a per-frame GPU step cap and a dt accumulator.
- Dispatch from `_process` with a fixed-step accumulator: same cap needed; body footprints uploaded at render time are up to one tick stale.
- Impulse readback arrives per render frame but must be applied per physics tick; with two ticks per frame or two frames per tick, impulses are double-applied or dropped unless they are integrated into a per-tick accumulator with a timestamp.

Also `rendering/rendering_device/vsync/frame_queue_size` (2) is the readback latency knob; setting it to 1 cuts a frame at some throughput cost. The doc should state the chosen loop and cap.

### I10. Connectivity collapse: "recompute only the region an edit touched" is not well-defined, and the cited Nilles figure is for a different algorithm

A flood fill from the hull is a global property: whether a roof section is supported can depend on spans several tiles away. Restricting label propagation to dirty tiles gives wrong answers at tile borders (a roof held up only from the neighbouring tile reads as disconnected). The honest version is window-wide iterative label propagation with a per-frame iteration budget, convergence in O(longest support path / cells per iteration) passes, which for a 2 km window with long tunnels can be hundreds of passes spread over frames; the doc already accepts latency, so this is a cost statement, not a blocker. Nilles et al.'s "~1 ms at 2048² for support" is a local bedrock-support heuristic, not a connectivity labelling, so it does not bound this cost. The jump-flood distance transform for the roof-span rule is correctly costed (log2 N = 10 passes).

### I11. Where C++ becomes unavoidable: the doc's trigger ("only when the profiler says so") is right but it names the wrong candidates, and misses the real one

- Tile compression to span runs on the CPU in GDScript: a per-cell loop is ~1 µs per operation, so a 1024-cell strip × ~10 ops is 10-20 ms every window step (every ~8 frames at run speed), and a full window load (1M cells) is tens of seconds. This is the first place GDScript breaks. The lazy fix is to never interpret cells on the CPU: run the compression as a compute pass and store the tile as an opaque PackedByteArray blob; the CPU moves blobs, the GPU decodes them. Then no C++ is needed for streaming.
- Surface-nets output → `ConcavePolygonShape3D.set_faces`: fine in GDScript because `PackedByteArray.to_vector3_array()` exists in 4.7 (verified in the class reference), so a readback becomes faces with no per-vertex loop.
- Heightmap colliders: `PackedByteArray.to_float32_array()` or `Image.create_from_data(..., FORMAT_RF, bytes)` + `update_map_data_from_image(img, 0.0, 1.0)` (identity remap) are native. Fine.
- Connectivity search: the doc puts it on the GPU in the solver table but lists it as a GDExtension candidate in the CPU-boundary paragraph; pick one. GPU is the right one.
- A GDExtension cannot reach Jolt: the module exposes no classes (no `JoltPhysicsServer3D.xml` in the 4.7 class reference); everything goes through `PhysicsServer3D`, so C++ buys nothing on the physics side.
- Build burden if it is ever needed: godot-cpp matching 4.7, SCons, Xcode toolchain, one binary per platform and architecture, and a `.gdextension` manifest; a day of setup, then ongoing CI. Not large, but not "small" either.

---

## Minor

### M1. "This needs the Forward+ renderer" (6.8) — needs a RenderingDevice renderer: Forward+ or Mobile
Compute tutorial: "Compute shaders can only be used from RenderingDevice-based renderers (the Forward+ or Mobile renderer)". Only Compatibility (OpenGL) lacks it; `get_rendering_device()` returns null there and in headless mode (so the project's headless test runner cannot test any of this; tests of the GPU path need a windowed run). The project is Forward+ by default, so no action beyond wording.

### M2. "schedule the work through the render thread so it lands in the frame in order" — only meaningful under thread_model = 2
`RenderingServer.call_on_render_thread(callable)` exists. Under the project's default `rendering/driver/threads/thread_model = 1` the render server runs on the main thread, the callable runs immediately, and RD calls from `_process` already precede the frame's draw lists. The ordering guarantee comes from the render graph, not from the callable. Say "wrap RD calls in call_on_render_thread so the code survives switching to multi-threaded rendering".

### M3. Barriers between stencil passes are not automatic inside one compute list
`compute_list_add_barrier` in 4.7 ends the list and begins a new one in the render graph (`rendering_device.cpp` lines 7069-7096), and the graph then inserts the real barrier from resource tracking. Dispatches within one list without it may overlap (the RD doc example says "No barrier, let them run all together"). Every ping-pong pass therefore needs an `add_barrier` or its own list. Forgetting one produces GPU-dependent races. Twenty barriers per frame cost tens of µs of GPU idle each, negligible.

### M4. Async readback: present, but attribute and constrain it correctly
`buffer_get_data_async(buffer, callback, offset_bytes = 0, size_bytes = 0)` and `texture_get_data_async(texture, layer, callback)` exist in 4.7.2 (installed class reference). Latency per the 4.7 XML: "the delay corresponds to the amount of frames specified by frame_queue_size" (default 2), so "one or two frames" should read "frame_queue_size frames, default 2". They are guarded by `ERR_RENDER_THREAD_GUARD` and are for the main device; a 4.5.1 forum report (forum.godotengine.org/t/buffergetdataasync-not-executing/135711) shows the callback never firing on a local device. Whether 4.4 was the first release is not load-bearing and was not verified.

### M5. Integer-format textures in material shaders need a verification step
`usampler2D`, `isampler2D`, `usampler2DArray` exist in the shading language (verified). The uniform hint table lists hints only for `sampler2D`, so filter/repeat hints on integer samplers may be rejected; use `texelFetch`. Also confirm that `RenderingServer.texture_rd_create` on an `R32_UINT` texture binds correctly to a `usampler2D` in a `ShaderMaterial` (the official Compute Texture demo uses `R32_SFLOAT` + `sampler2D`). If it does not, the fallback of carrying bits in an `R32_SFLOAT` texture via `floatBitsToUint` is unsafe (NaN patterns can be canonicalised); use `R32_SINT` or 16-bit pairs instead.

### M6. Pull-vertex and MultiMesh rendering: fixed counts and AABBs
`VERTEX_ID` and `INSTANCE_ID` exist as vertex built-ins (verified). But the scene renderer has no indirect draw, so a pull-vertex surface-nets mesh must be an ArrayMesh with a fixed maximum vertex count and degenerate triangles for unused slots; a MultiMesh of parcels uses `instance_count` with `visible_instance_count`. Both, and every displaced tile, need `GeometryInstance3D.custom_aabb` covering the full displacement range, or they get frustum- and shadow-culled.

### M7. Fixed-point stall and overflow
Millimetre units in 32-bit hold ±2147 km of height, fine; but flux smaller than one unit per step truncates to zero, so thin films and slow seepage stall unless flux carries a fractional residual (an extra field) or uses µm units (±2147 m range, still enough for heights). Window-wide reductions (mass audits) overflow 32-bit (10⁶ cells × 10⁶ mm); use a hierarchical sum or 64-bit, noting Godot does not guarantee the 64-bit atomic extensions and Metal has no 64-bit buffer atomics on most Apple GPUs. "GLSL has no float atomics in any case" is loose: `GL_EXT_shader_atomic_float` exists on Vulkan but Godot's glslang pipeline does not enable it and Metal lacks float add; "none you can rely on" is accurate.

### M8. Su et al. figures quoted slightly loosely
Section 2 "1024² ... 2 to 3.5 ms" and 6.8 "0.5 to 3.5 ms at 1024²": the 3.54 ms is 512×1024 (Seepage) and 0.46 ms is 512² (Dam Break); the two 1024² scenes are 2.04 and 2.16 ms. 6.4 quotes Seepage correctly as 512×1024.

### M9. GDScript orchestration of ~20 dispatches: plausible, with two conditions
Estimate (not measured here; headless mode has no RD): ~5 RD calls per dispatch × 20 = 100 Variant-boundary calls at ~2-5 µs plus push-constant `PackedByteArray` assembly, ≈ 0.3-1 ms CPU per frame. Fine, provided uniform sets are created once per ping-pong orientation (recreating `uniform_set_create` per frame leaks and costs) and push-constant arrays are prebuilt. GDScript has no struct packing, so std430 layouts and 16-byte alignment are hand-maintained with `encode_*`, a recurring source of silent bugs.

### M10. Scaled heightfield tiles
`HeightMapShape3D` grid spacing is fixed at 1 unit; 2 m cells mean scaling the CollisionShape3D by (2, 1, 2). The HeightMapShape3D docs say this requires Jolt, which the project uses; Jolt wraps the shape in `ScaledShape` and accepts non-uniform scale. Fine, but state it.

### M11. Debugging and tooling cost
RenderDoc only works with the Vulkan driver (and not with local devices); on macOS the Metal driver needs Xcode GPU capture with no in-engine trigger. `RenderingDevice.capture_timestamp` / `get_captured_timestamp_gpu_time` exist and should be the first thing wired in. Validation layers are opt-in (`--gpu-validation`). Shader errors arrive at runtime as strings from `shader_compile_spirv_from_source`. None of this blocks the plan; it is a week of tooling the doc does not budget.

### M12. Vertex-shader precision
Mapping `(s, z)` to the cylinder with `θ = s / R` in float32 at `s` up to 20 km gives ~2 mm vertex jitter; compute per-tile in the tile's local frame (MODEL_MATRIX per tile) so per-vertex trig stays small. Scene positions at 3.2 km have 0.24 mm ulp, consistent with the doc's floating-origin plan.

---

## Verified (one line each)

- `RenderingServer.get_rendering_device()` + `compute_list_*` on the main device, no `submit`/`sync` (those are local-device only per the 4.7 XML).
- `Texture2DRD`, `Texture2DArrayRD`, `Texture3DRD` exist; `texture_rd_create` wraps the RD RID without copying.
- `buffer_get_data_async` / `texture_get_data_async` exist with the signatures above.
- `INSTANCE_ID`, `VERTEX_ID` vertex built-ins; `usampler2D(Array)` sampler types.
- `call_on_render_thread`, `is_on_render_thread` exist.
- `HeightMapShape3D.map_data`, `update_map_data_from_image`, NaN holes under Jolt; Jolt module mesh fallback for non-square or < 4-wide maps; odd sample counts padded.
- Atomics on `uint` storage buffers: core GLSL, work on Vulkan and Metal.
- `PackedByteArray.to_float32_array` / `to_vector3_array` for native-speed readback conversion.
- Project is Jolt + Forward+ + Metal on macOS by defaults in `project.godot`.
- The 10 m drop row (1.43 s, 0.5 m) matches the feasibility doc's Jolt measurement (1.433 s, 0.520 m).

## Buildability verdict on the staged plan (6.8 "Order of work")

Buildable in GDScript + GLSL by a small team, with no C++ required if streaming keeps tiles as GPU-produced opaque blobs (I11). The first milestone is larger than "three textures": it must include staging textures for region upload/readback (I1, I2), ping-pong + barriers (M3), `Texture2DRD` tile shaders with custom AABBs (M6), the async readback → heightfield path with its latency (I6), and a decision on the sim loop (I9). Expect the first measured frame on an Apple-silicon laptop to be several times slower than Su et al.'s 4080 figures (I4); plan for a 512² window there.
