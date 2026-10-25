# Adversarial review: docs/terrain-research.md (physics, simulation design, scale)

> Independent adversarial review of `terrain-research.md`, run 2026-10-24 by a fresh agent that was given the document and the repository but not the author's reasoning. Its findings are folded into the main document; this file is kept as the record.

Reviewed: `/Users/matt/ArtificialGravityDemo/docs/terrain-research.md` (working-tree version, including the uncommitted section 6.8).
Checked against: `godot/station.gd`, `godot/tests/test_drop_math.gd`, `godot/tests/test_station.gd`, `godot/main.tscn`, `godot/box.gd`, `docs/godot-port-feasibility.md`; Su et al. 2023 (author PDF, full text); Godot large-world-coordinates page; Nilles et al. VMV 2024 (abstract only; the EG server refused connections today, so body numbers remain unverified).

Station parameters used throughout: R = 3200 m, g = 9.8 m/s² at the floor, Ω = √(g/R) = 0.05534 rad/s, period 113.5 s. All arithmetic is in `scratchpad/fall.py` and the inline Python runs recorded below.

Counts: **Critical 3, Important 10, Minor 8.**

---

## Critical

### C1. §5A/§6.3/§6.4 — Rivers have no source; the water model cannot keep requirement 1's rivers alive

Claim: "Rivers and lakes are just `h_w` over the generated channels" (§5A); "Drying. By drainage only. The station is closed, so evaporation would need a global water budget ... Off by default" (§6.4); water is simulated "only in an active window around the player" (§2, §6.8).

Problem: a river is a flux from a source to a sink. The design has sinks (the ring sea, lakes) and no sources: no rain, no springs fed from a return path, no inflow boundary condition at the window edge. Inside the 2 km window every river reach drains into the sea or the window boundary within minutes of game time (a 2 m/s river clears 2 km in ~17 min) and the channel goes dry; outside the window `h_w` is frozen, so the river "exists" only where nobody is looking. At the window boundary either water piles up (reflective) or vanishes (outflow) — neither is stated. The same applies to lakes fed by rivers.

Correction: the design needs a water budget as a first-class component, not an off-by-default option: (a) per-river discharge recorded by the generator (Fischer gives drainage basins, so discharge per reach is available), (b) source cells at headwaters inside the window injecting that discharge, (c) a matching sink at the sea or at the window edge, and (d) a steady-state initialisation of `h_w` and velocity from the generator's discharge so the river is in equilibrium when the window arrives rather than starting from a static pool. Say explicitly what happens to water that reaches the window edge.

### C2. §6.4 — Lakes drain through their banks and shorelines fail under the design's own rules

Claim: "a mandatory impermeable liner of clay or rock under every generated lake and river bed"; "Lakes and rivers hold water only because of their liners"; conductivities scaled up "by two or three orders of magnitude".

Problem 1 (drainage): the liner is under the bed only. The banks above the liner are dirt at K_play = 10²–10³ × (1e-5 … 1e-3 m/s) = 1e-3 … 1 m/s. Dupuit discharge through a bank per metre of shoreline is q = K(h₁² − h₂²)/(2L). For a 500 m × 500 m × 10 m lake (2.5e6 m³, 2 km shoreline) draining to a valley floor 10 m lower over L = 100 m:

| K_play (m/s) | Q (m³/s) | lake empties in |
|---|---|---|
| 1e-3 | 1 | 29 days |
| 1e-2 | 10 | 69 h |
| 1 | 1000 | 42 min |

At the doc's own scaled rates every lake with dirt banks empties sideways in hours to minutes; the liner does nothing against this.

Problem 2 (failure): the lake wets its banks by infiltration/lateral seepage; saturated dirt has stable slope 35° and repose 20° (table §6.4). Any generated bank, cut, or noise-detail steeper than that fails on first contact with the water table, so every shoreline in the window slumps into the lake the first time the window arrives, and the slumped loose material at repose 20° then needs ~27 m of horizontal run per 10 m of bank height. This is a station-wide landslide, not an occasional event.

Correction: the liner must cover the wetted perimeter up to and above the water line (or the bank material under the wetted zone must be clay/rock), the generator must enforce bank slopes below the *saturated* stable slope of their material within a seepage distance of any water body, and the "Consequences worth designing for" paragraph should say so. Also give the lake a water balance (C1): with no inflow even a sealed lake only loses.

### C3. §2 — The "flat world" premise ignores that terrain thickness is a large fraction of R

Claim: "the hull unrolls isometrically ... gravity exactly normal to the undeformed surface everywhere ... The only differences from a flat world are: a periodic boundary; long straight features bend; no natural ocean boundary."

Problem: the hull surface is developable; the terrain volume on top of it is not. Height is "radial depth inward from the hull", so a cell at height h has circumferential width (1 − h/R)·Δs, gravity g(h) = g₀(1 − h/R), and a 1 m slab's volume is ∝ (R − h). Numbers:

| relief h | g/g₀ and s-cell width factor | volume of a 2 m × 2 m × 1 m slab |
|---|---|---|
| 100 m | 0.969 | 3.87 m³ |
| 500 m | 0.844 | 3.37 m³ |
| 1000 m | 0.688 | 2.75 m³ |
| 2000 m | 0.375 | 1.50 m³ |

Consequences for the design as written: (a) **mass conservation**: §6.8 stores "heights and masses as integers in millimetre-class units" and §5A says digging "is conserved by construction". Moving 1 m of loose height from a valley cell to a 1 km ridge cell changes its physical volume by 31 %; with heights as the conserved integer, mass is not conserved on any slope — the stated requirement 2 fails silently. (b) **slopes**: repose and stable-slope tests use Δh/Δs; at 500 m relief the s-direction slope is understated by 16 % (a 35° repose reads as 30.5° in grid units), and the roof-span distance transform is wrong by the same factor. (c) **shallow water/sand**: the grid spacing is anisotropic and g varies by tens of percent across the window; both solvers in §6.8 assume neither. On Earth h/R ≈ 1e-3 and all of this is ignorable; here it is 0.03 per 100 m of relief.

Correction: state a relief budget (e.g. "with relief under 150 m all factors are under 5 % and are ignored") *or* put the per-row factors in: cell area A(h) = (1 − h/R)ΔsΔz in every flux and mass conversion, slopes with the local metric, g(h) in the SWE/SSE pressure terms. Requirement 1 asks for "mountain ranges" and the doc never says how high; it must.

---

## Important

### I1. §6.6 — "Rain released at 500 m lands about 220 m antispinward" is the drag-free number; rain gets ~60 m

The 222.6 m I recomputed from the inertial solution is correct for a dense body in vacuum. Rain is not that: drops reach terminal velocity (~9 m/s for large drops) within a few metres, after which the antispinward drift saturates at u = 2Ω v_t²/g ≈ 0.9 m/s. Integrating the rotating-frame equations with the station's own quadratic drag law (`Station.drag_force`, isothermal density) for a 500 m fall:

| terminal speed | fall time | lands antispinward | slant at impact |
|---|---|---|---|
| none (doc) | 11.5 s | 223 m | 32° |
| 9 m/s (rain) | 58 s | 58 m | 6.8° |
| 20 m/s (spray/jets) | 28 s | 120 m | 15° |

The slant is still visible, but the number is off by ~4×. Say "a dense object" or quote ~60 m for rain.

### I2. §6.5 — Parcels integrate `acceleration_at` only, with no drag; box.gd applies both

Water in free fall breaks up and is strongly drag-limited; the parcel scheme drops drag entirely and so hits at 43.9 m/s from 100 m and 61.6 m/s from 200 m. Consequences: a 50 kg parcel carries 2.2–3.1 kN·s of impulse (a 100 m, 10 m³/s fall exerts 440 kN on whatever is under it — enough to launch any Jolt body in the scene); the plunge-pool inflow velocity of 10.9–21 m/s drives the SWE CFL at 2 m cells; and the deflection in the §6.5 table is an upper bound for water (with v_t = 20 m/s the 100 m deflection drops from 17.2 m to 15.7 m and impact speed from 44 to 20 m/s). The same applies to the "dirt thrown by the auger" and "spray" in §6.6. `box.gd` already applies `drag_force`; parcels should take the same call with a tunable area per parcel. Add a line to the table saying it is the drag-free envelope.

### I3. §2, §5A, §6.8 — Su et al.'s timings are misattributed and then used as the budget for a different, larger solver

Verified from the paper (Table 2, RTX 4080): Castle 512×1024 0.73 ms; Spring 1024² 2.16 ms; Dam Break 512² 0.46 ms; **Seepage 512×1024 3.54 ms**; Flush 1024² 2.04 ms; Canyon 600×800 0.61 ms; Dam Break at 1024² 2.11 ms (Fig. 4). Hence:

- "Su et al. 0.5 to 3.5 ms per step at 1024²" (§5A, §6.8 table) and "the grid size Su et al. run in 2 to 3.5 ms" (§2) are wrong in the way that matters: the 3.54 ms figure is for *half* the cells. The Seepage scene is the closest analogue to this project (water inside sand); scaled to 1024² it is ~7 ms before anything is added. §6.4 states the 512×1024 correctly, so the document contradicts itself.
- §6.8: "Su's Drucker-Prager term was 70 % of their step" — the paper says "over 70 % ... on two operations, deformation gradient projection, and boundary conditions update": projection 38–45 %, boundary update 25–39 %. Dropping Drucker–Prager saves roughly 45–50 %, and the boundary-type pass, which this design makes *harder* (spans, materials, pressurised cells), stays.
- "a few milliseconds per frame on a mid-range GPU" — the RTX 4080 is a high-end part; Su's Δt per step is 0.009–0.045 s (scene-dependent) so a 60 Hz frame may need two steps; and the doc then adds per-layer water, a seepage pass, parcels with atomics, three-material blending, connectivity, a distance transform, prefix-sum rebuilds, and Godot `RenderingDevice` dispatch overhead for ~20 passes. None of that is in Su's number. "The engineering is in the data layout ..., not the solvers" is asserted, not supported.

Correction: quote the table per scene, use Seepage at 1024²-equivalent (~7 ms) as the water+sand baseline, and present the §6.8 "evidence or estimate" column as estimates with no measured total.

### I4. §6.2 — Connectivity from the hull treats only solid as support; loose and recompacted fill do not hold anything up

"Flood-fill solid cells from the hull ... Anything not connected falls." Loose spans are not solid, so a solid span resting on loose material is disconnected and fails. That is the *normal* state after the cycle the document is built around (dig → fill → recompact under something): a roof span above a partially recompacted floor, a rock span on top of scree, a tunnel floor refilled and a wall rebuilt on it. "Compacted mixed material becomes a solid span of fill" only helps once the threshold is passed; before that, anything above it drops. Loose material bears load (that is what a spoil heap does). Correction: loose and fill spans count as support with their own (lower) strength, i.e. the fill is a weak link, not a gap; define what "connected" means across a loose span.

### I5. §6.4 — The Dupuit–Forchheimer step is written for a flat base and will be unstable at the play-scaled conductivities

(a) "∂h/∂t = (K/n)·∇·(h∇h) with the water-table height a height field over the columns": for a perched table on a clay lens with base elevation z_b, the Boussinesq form is n ∂h/∂t = ∇·(K (h − z_b) ∇h). Using the table height (above the hull) as the transmissivity instead of the saturated thickness over-weights every perched aquifer by h/(h − z_b), and the specific yield (drainable porosity) should replace n. (b) Explicit stability: Δt ≤ nΔx²/(4Kh). With n = 0.4, Δx = 2 m:

| K_play | h = 5 m | h = 20 m |
|---|---|---|
| 1e-3 m/s | 80 s | 20 s |
| 1e-2 m/s | 8 s | 2 s |
| 1 m/s | 0.08 s | 0.02 s |

The "about 6 Hz" rate (Δt = 0.17 s) is unconditionally stable only for K_play ≲ 1e-2 m/s at modest thickness; the upper end of "two or three orders of magnitude" over coarse sand blows up. Either cap the scaled K and say so, or use an implicit (Jacobi/red-black) diffusion solve. (c) Wording: K is hydraulic conductivity (m/s), not permeability (m²); the table conflates them.

### I6. §6.8 table — Collapse cost rests on a Nilles number that measures a different algorithm

"connectivity and roof span ... iterative label propagation, jump-flood distance transform — Nilles et al.: about 1 ms at 2048² for support plus horizontal erosion". The Nilles abstract (confirmed) describes "propagating bedrock connectivity while incorporating the weight of each column" — a per-column iterative support pass over a fixed layer stack, not a connected-component labelling of a span graph. Iterative label propagation converges in O(path length) passes: a 1 km tunnel at 2 m cells needs ~500 full-window passes, and a dirty-region restriction only helps if the region is small. Jump flood is O(log N) and fine. Either use pointer-jumping/union-find on the GPU (log-depth) or state the worst case. The 1 ms itself could not be verified (EG server unreachable); keep it marked as a lead and do not put it in an "evidence" column.

### I7. §6.2/§6.4 — Generated terrain is never checked against the stability rules, and the window edge freezes everything outside

Dry dirt has a 60° stable slope and 4 m roof span; noise detail at walkable scale, Fischer's monotone growth, cliffs where bedrock does not reach the surface, and "clay lenses from thresholded noise" will all produce faces steeper than the material's stable slope. The rules run only inside the column window, so the first visit to any region triggers the failures the generator built in, and material slumps en masse while the player watches. Combined with C2 this makes first contact with every new area a collapse event. Correction: a generation-time pass that enforces each material's *saturated* stable slope (where water can reach) and dry slope elsewhere, and a note that failures must be pre-settled before a tile is first streamed into the window.

### I8. §6.3 — The ceiling/pressure rule has no conservation statement and the wrong propagation speed for siphons

"When a water span fills its gap, further inflow raises a pressure head instead of height." If the gap is full, inflow mass has to go somewhere: either the cell holds more mass than its volume (compressible water, which is what Dwarf Fortress does; the surplus must be released when the roof is dug), or the inflow must be refused and pushed back upstream in the same step (an elliptic solve, not a local rule). The doc says neither, so "mass is conserved end to end" is unsupported for flooded tunnels. With local flux the pressure signal travels one cell per step: a 500 m siphon at 2 m cells responds after ~250 steps (4 s at 60 Hz) and will oscillate, which the doc notes but does not bound. Also the pressurised span pushes up on the roof above it; §6.3 "Loads" counts water only as overburden. State the model (compressible storage with a release rule is the honest cheap one) and the damping.

### I9. §5A/§6.7 — The risk rating was never updated for section 6

§5A keeps "Risk: low to medium. Every piece has a published real-time counterpart", and §6.7 says "the rest of A is unchanged". Of the §6 components, per-layer water flux (Nilles, lead), pressurised spans (game analogues only), three-material seepage with perched tables (no source), waterfall parcels with Coriolis landing (Chentanez, background), connectivity/roof-span collapse (game analogues), and mixed loose material (explicitly unsupported by Servin) have no verified real-time counterpart — §8 says as much. The extended A is medium-to-high risk by the document's own evidence standard; say so, and separate the risk of the dense 2.5D core (low) from the extensions (high).

### I10. §5/§6.7 — Alternatives dismissed by conflation or not considered

- "Things to refuse: ... simulation in GDScript" is treated as "no CPU simulation". A CPU cellular automaton in a small GDExtension over a 256–512 m active region (16k–65k columns at 2 m, 10–20 Hz) is how Dwarf Fortress, Timberborn and Noita — the doc's own precedents for pressure, column water and collapse — do it, needs no readback latency, no `Texture2DRD` plumbing, no fixed-point atomics, and talks to Jolt directly. The doc never costs this option against the 20-pass GPU pipeline; for a single-player sandbox where tools act within tens of metres it may be the simpler engineering.
- A dense 3D occupancy grid over the window's top tens of metres (1024² × 32 layers × 1 B ≈ 34 MB) is never considered as the tunnel representation. It makes connectivity, roof span and per-layer water trivial 3D stencils and removes the prefix-sum span buffer; the doc's own "voxel bubble" is this at 200 m, so the question is only how far it extends.
- Discrete block layers (Timberborn/Minecraft-style integer spans) versus continuous span heights: the former makes support and flooding tests exact and cheap; the doc assumes continuous spans without discussing the trade.
- B is dismissed as "CPU-bound at ~1k particles" without noting that the only requirement B uniquely serves (tool reaction force for the auger) could be met by the IAARC analytical model the doc already recommends in §4.5, which makes B unnecessary rather than "an add-on". Say that.

---

## Minor

### M1. §6.5 — Wrong test cited for the 10 m row
"The 10 m row matches the drop test already in the repository (1.432 s, 0.529 m)" and "`test_drop_math.gd` already pins it against the exact inertial-frame solution". `test_drop_math.gd` runs at R = 500 m, where the exact values are 1.450 s and 1.362 m. The 1.432 s / 0.529 m figures come from `tests/test_station.gd` (Jolt body on the real 3200 m hull) and the measurement in `docs/godot-port-feasibility.md`. Cite `test_station.gd`, and note that `test_drop_math.gd` only checks `fictitious_acceleration` at a different radius.

### M2. §6.5 — "within 3 %" for the small-angle estimate
Ωgt³/3 at 100 m gives 17.9 m against the exact 17.2 m: +3.9 %. At 200 m it is +8 %, at 500 m +23 %. Say "about 4 % at 100 m and worse above".

### M3. §6.2/§6.4 — Roof span versus distance to nearest wall differ by a factor of two
The table gives a "maximum unsupported roof span" (a width), but the rule fails a cell "when its horizontal distance to the nearest wall exceeds that limit" (a half-width). As written, a dirt tunnel can be 8 m wide. Pick one and relabel the table.

### M4. §6.4 — Repose table contradicts the cohesion law the doc adopts
"loose form and repose, dry → saturated: soil 35° → 20°" is monotone. Su et al.'s piecewise-linear cohesion (verified: Fig. 3 and §3.3.3, "adding a small amount of water makes the sand more cohesive, while adding a large amount of water makes the sand collapse") peaks at intermediate saturation: damp dirt holds steeper than dry. Give three columns (dry, damp, saturated) or say the table's two values bracket a non-monotone curve.

### M5. §2 vs §6.8 — Sagitta claim contradicts the rendering plan
§2: the 4–16 cm flat-tile error "vanishes if the render mesh is built from the same locally planar tile". §6.8: the vertex shader "displaces radially and maps onto the cylinder", i.e. the render surface is curved and the collider is flat, so the error does not vanish; resting objects float or sink by up to 16 cm at 64 m tiles. Also, planar tiles meet at a 0.57° crease per 32 m. Pick one surface for both and say which.

### M6. §2 — "never pushed sideways" is exact only for level flow
Downhill flow has a radial component v sin α, giving a circumferential Coriolis acceleration 2Ω v sin α. For a 3 m/s stream on a 30° slope that is 0.17 m/s², 3.4 % of the along-slope gravity, a ~2° cross-slope push. Negligible for routing, but "the Coriolis acceleration is purely radial" should read "for flow on a level surface".

### M7. §4.2/§6.1/§9 — Nilles attribution and the repo
The GitHub repository the doc cites for the VMV 2024 simulation paper now states it holds the code of the VMV 2025 follow-up, Nilles & Müller, "Fast Rendering of Large-Scale Dynamic Multi-Layered Height Maps", which exists precisely to fix the "rendering up to 10× slower than simulation" problem for which §6.1 proposes its own fix. Cite the follow-up. The 6 ms / 23 ms at 2048² / 4096² on an RTX 3070 are confirmed by the abstract; "84 B per column", "~1 ms support" and the "at best physically plausible" quote remain unverified (full text unreachable today) and should not be quoted as if read.

### M8. §6.5 — Parcel mass on dry solid ground has nowhere to go
"A parcel hitting solid ground only wets it." Rock "takes nothing", so a parcel landing on bare rock (the common case under a cliff) deposits no mass anywhere; dirt takes only up to its pore space. The remainder must become a surface water span (`h_w`) on that cell or the scheme leaks mass exactly where waterfalls land. Open question 10 covers side faces but not this.

---

## Checked and found correct (listed because the brief asked for these specifically)

- Coriolis for in-surface flow: −2Ω×(v_θθ̂ + v_zẑ) = 2Ωv_θ r̂, radial, spinward heavier. 2Ω/g = 1.13 %/(m/s): "1.1 % per m/s" is right. Ω = 0.0553 rad/s, period 113.5 s.
- Deflection table (exact inertial solution, lag = R(x − atan x), x = √(R² − a²)/a; tangential impact speed Ωc²/R; radial Ωac/R):

| h | t (s) | lag (m) | v_antispin (m/s) | angle |
|---|---|---|---|---|
| 10 | 1.432 | 0.53 | 1.11 | 4.5° |
| 50 | 3.232 | 5.99 | 5.49 | 10.1° |
| 100 | 4.627 | 17.2 | 10.9 | 14.4° |
| 200 | 6.707 | 50.4 | 21.4 | 20.4° |

All doc entries within 2 %. Direction (antispinward) matches the sign convention in `test_drop_math.gd` (spin +Z, spinward +X at the bottom).
- Scale arithmetic: circumference 20.1 km; 603 km²; 603 M / 151 M / 38 M cells; 1.2 GB / 302 MB / 75 MB; 5.4 GB / 1.36 GB / 340 MB; sagitta 4 cm / 16 cm; 1024² × 2 m = 2 km; bubble 2 M cells; 200 spawns/s and ~920 live parcels for 10 m³/s over 100 m.
- Godot float guidance: docs give [4096; 8192] as the recommended single-precision range for third-person; the doc's "4 to 8 km" is a fair reading. Godot 4.4 async readback exists (`texture_get_data_async`, `buffer_get_data_async`).
- Su et al. statements in §4.1 (four fields, static H, T = 3 sand updates per water update, >70 % in projection + boundary update, 500k-particle MPM comparison at 700 ms/step, waterfalls as an SWE limitation) are accurate to the paper.

## Appendix: fall.py used for the arithmetic

```python
import math
R=3200.0; g=9.8; W=math.sqrt(g/R)
print("Omega",W,"period",2*math.pi/W,"2W/g %",200*W/g)
def exact(h,R=R,W=W):
    a=R-h; c=math.sqrt(R*R-a*a); t=c/(W*a); x=c/a
    lag=R*(x-math.atan(x))
    vt=W*c*c/R; vr=W*a*c/R
    return t,lag,vt,vr,math.degrees(math.atan2(vt,vr)), W*g*t**3/3
for h in (10,50,100,200,500):
    t,lag,vt,vr,ang,sm=exact(h)
    print(f"h={h:4} t={t:.3f} lag={lag:.2f} vt={vt:.2f} vr={vr:.2f} |v|={math.hypot(vt,vr):.1f} ang={ang:.1f} smallangle={sm:.2f} ({100*(sm/lag-1):+.1f}%)")
# test_drop_math uses R=500
t,lag,vt,vr,ang,sm=exact(10,500,math.sqrt(g/500)); print("R=500 h=10:",round(t,3),round(lag,3))
# rain with quadratic drag: integrate in rotating frame with station's drag law, terminal 9 m/s
def sim(h,vt_term,rho_var=True,dt=1e-3,drag=True):
    # 2D in plane: position (x,y), origin on axis, start at (0,-(R-h)), spin about +z
    a=R-h; x,y=0.0,-a; vx,vy=0.0,0.0; t=0
    k=g/(vt_term**2)  # drag accel = k*rho_rel*|v|*v
    while math.hypot(x,y)<R:
        r=math.hypot(x,y)
        # centrifugal W^2 r outward, coriolis -2 W z x v = -2W*(-vy, vx) = (2W vy, -2W vx)
        ax=W*W*x+2*W*vy; ay=W*W*y-2*W*vx
        if drag:
            rho=math.exp(-0.5*W*W*(R*R-r*r)*1.225/101325) if rho_var else 1.0
            s=math.hypot(vx,vy); ax-=k*rho*s*vx; ay-=k*rho*s*vy
        vx+=ax*dt; vy+=ay*dt; x+=vx*dt; y+=vy*dt; t+=dt
    lag=-math.atan2(x,-y)*R
    return t,lag,vx,vy,math.degrees(math.atan2(-vx,-vy))
for h in (100,200,500):
    print("nodrag h",h,[round(v,2) for v in sim(h,9,drag=False,dt=2e-3)])
    for vt_ in (9,20,40):
        print(" drag h",h,"vterm",vt_,[round(v,2) for v in sim(h,vt_,dt=2e-3)])
# steady drift estimate 2 W vt^2/g
for vt_ in (9,20,40): print("u_steady",vt_,2*W*vt_**2/g)
# scale table
circ=2*math.pi*R; L=30000; A=circ*L; print("circ",circ,"area km2",A/1e6)
for c in (1,2,4): n=A/c**2; print(c,"m cells",n/1e6,"M; 2B",n*2/1e9,"GB; 9B",n*9/1e9,"GB")
for w in (32,64): print("sagitta",w,w*w/(8*R))
# g at height
for h in (100,200,500,1000,2000): print("h",h,"g/g0",1-h/R,"cell width factor",1-h/R)
# Dupuit explicit stability dt <= n dx^2/(4 K h)
for K in (1e-5,1e-3,1e-2,1.0):
    for hh in (5,20): print("K",K,"h",hh,"dtmax",0.4*4/(4*K*hh))
```
