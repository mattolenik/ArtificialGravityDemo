# Terrain Cave-in (Slope Stability) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A dug hole caves in like real dirt: solid walls standing steeper than their stand slope crumble into loose dirt, which the existing slump spreads at repose, so the hole becomes a loose-sided bowl instead of a cluster of 1 m columns at arbitrary depths (the user: "when digging a hole it leaves very jagged angled slopes that look unnatural"; chosen over a rounder scoop bite).

**Architecture:** The research doc's slope-stability rule (6.2: "a solid face steeper than its material's stable slope at its current saturation fails: the material above the failure line becomes loose and slumps to repose") runs inside `sim.glsl`'s step. The flux pass finds, per cell, the steepest excess of its surface over a *disturbed* neighbour's ground (the neighbour's edit mask set) past the stand slope and writes `slump_rate` of it, at most down to `bedrock_top`, to a new `flux_fail` image; the apply pass cuts that from the surface (clay with it, material by the strata, as the scoop does) and adds it to the cell's loose times the swell, flags activity and masks the cell. Only toward disturbed ground, so generated hillsides (up to 60° with thin soil) stand until something beside them is dug or moved; the loose piled against a wall counts as the neighbour's ground, so rubble buttresses it; nothing fails toward a blocked cell (the auger's casing); a wall across a tile edge that would fail toward a disturbed cell has its tile woken. Per-material numbers (stand slope dry and saturated, swell) go in a 48-byte storage buffer at binding 17 (the push constants are at 112 of the 128 bytes Vulkan guarantees).

**Tech Stack:** Godot 4.7.2, GLSL compute on the main RenderingDevice, GDScript; the Vulkan tool run through `tests/offscreen.sh`.

**Spec:** the brainstorm in chat (2026-10-29) and `docs/terrain-research.md` 6.2 and 6.4; `MaterialSet.stable_slope_dry` / `stable_slope_saturated` are the angles, dirt's dry one lowered from the research doc's 60° to 45° so a hole caves around the third scoop in one spot (the one number that sets the look).

## Global Constraints

- Conservation to float rounding: solid depth f becomes the annulus it filled over the new surface's area, times the swell (the scoop's product form); every change stored.
- No cell written by two invocations: the failure is decided in the flux pass from old state and applied by the cell's own apply invocation.
- Rock (material 2 and 3) never fails; the dead band is 1 mm of excess, so a bank generated exactly on the line (bank_slope_deg 35 = dirt's saturated stand) does not chatter in float.
- Never touch `user://worlds/default`; drivers run offscreen; `godot --headless --path . --import` after shader edits, never chained before a run.

## Review Focus

1. A wall that converts f per step and slumps exactly f·swell away leaves its loose unchanged: the activity gate must also look at f (`f > move_eps`), else the tile settles mid-collapse.
2. The failing cell's material changes when the cut reaches clay or rock: `top_material` after the cut, as the scoop does, and clay_top / clay_bottom clamped.
3. A wall across a tile edge (its tile inactive) is woken from the disturbed side; corners resolve through the cascade (its edge neighbours fail, move and wake it).
4. The auger's shaft holds while the auger stands (walls skip blocked neighbours) and caves on pickup and after a restart that loses the auger: the tool run's pickup and restart expectations change accordingly.
5. The stamps phase's 1 m bore and the lake phase's shore cut sit at or under 45° over 1 m cells: they must not cave (the pickup and restart phases prove the caving; the rest of the run proves the gate).

---

### Task 1: The rule in the simulation

**Files:**
- Modify: `godot/terrain/shaders/sim.glsl` (header, bindings 16 and 17, `stand_tan`, `top_material`, `wake` moved above `flux`, `flux(c, t, g)`, apply)
- Modify: `godot/terrain/terrain_sim.gd` (`_flux_fail`, `_materials`, `material_table()`, bindings, free)
- Modify: `godot/terrain/material_set.gd`, `godot/terrain/materials.tres` (dirt dry stand 45°)
- Test: `godot/tests/test_terrain_sim.gd` (`material_table` bytes)

- [ ] **Step 1: the test**: `sim.material_table()` is 48 bytes: tan 45° at 0, tan 70° at 4, tan 35° at 16, 1.25 at 32, 1.6 at 44.
- [ ] **Step 2: implement**, as the architecture says. `material_table() -> PackedByteArray` (CPU only, headless-safe).
- [ ] **Step 3:** `sh tests/run.sh` → every test PASS.
- [ ] **Step 4: Commit.**

### Task 2: The tool run proves it

**Files:**
- Modify: `godot/terrain/tool_run.gd` (header; `_pickup`; `_restart_mid_bore`; `_steepest_wall`)

- [ ] **Step 1:** `_pickup`: the auger picked up, within 1 s the shaft's cells hold loose (the walls caving); the 2 m³ column slumps in with it; settled, the loose over the box of 24 grew by 2 m³ plus the solid cut from the box times the swell within 0.5 %, the steepest wall (surface over a neighbour's surface + loose, over the edge distance) and the steepest ground slope of a loose cell at most tan 45° · 1.02, cells beyond the shaft lowered; then the shot `tool_cave`.
- [ ] **Step 2:** `_restart_mid_bore`: reads after the settle; the loose over the box grew by the solid cut from the box outside the shaft times the swell, within the old 0.3 m³ + 1 %.
- [ ] **Step 3:** `sh tests/offscreen.sh res://terrain/tool_run.tscn /abs/log` → PASS, 0 ERROR lines; the lake and stamps phases unchanged.
- [ ] **Step 4: Commit.**

### Task 3: Notes

- [ ] `docs/terrain-research.md` 6.8: a "Slope stability, 2026-10-29" paragraph with the run's figures; `docs/superpowers/plans/2026-10-28-terrain-slice-3-followups.md`: the rule's rulings (disturbed-only gate, 45°, the auger's casing) and what is left (the generator does not yet enforce the stand slope; moisture only through saturation; one swell per cut).
- [ ] Finish: superpowers:finishing-a-development-branch against `terrain`.
