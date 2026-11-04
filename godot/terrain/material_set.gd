## Per-material values, indexed by material id (0 dirt, 1 clay, 2 rock, 3 rock face). `color`, the swell,
## the repose angles, porosity, wetting distance and the stable slopes are used; the rest are the research
## doc's starting points (section 6.4), carried here so later slices read them from one place. Angles in
## degrees, lengths in m.
class_name MaterialSet
extends Resource

## 3 marks a cell whose bedrock_top the detail pass lifted to the surface because the face is steeper
## than 60°; its bedrock_top is not a stratum (read a neighbour or the macro map). Never written by an
## edit. Every array below carries rock's values for it.
const ROCK_FACE := 3

@export var names := PackedStringArray(["dirt", "clay", "rock", "rock_face"])
@export var color := PackedColorArray([Color(0.45, 0.33, 0.2), Color(0.6, 0.55, 0.45), Color(0.5, 0.5, 0.52), Color(0.5, 0.5, 0.52)])
## Water held per unit volume when saturated.
@export var porosity := PackedFloat32Array([0.4, 0.5, 0.0, 0.0])
## How far water soaks in from a water span.
@export var wetting_distance := PackedFloat32Array([3.0, 0.1, 0.0, 0.0])
## Volume gained on loosening.
@export var swell_factor := PackedFloat32Array([1.25, 1.35, 1.6, 1.6])
## Repose angle of the loose form, dry, damp and saturated (0 = slumps).
@export var repose_dry := PackedFloat32Array([35.0, 40.0, 40.0, 40.0])
@export var repose_damp := PackedFloat32Array([40.0, 45.0, 40.0, 40.0])
@export var repose_saturated := PackedFloat32Array([20.0, 0.0, 40.0, 40.0])
## Longest unsupported roof of the solid, dry and saturated: the cohesion that lets a roof span, and (the
## tunnels design) the free height of the slope stability rule: a wall fails only when it is both steeper than
## the stable slope and taller than this, so a pit under it keeps its cut shape and a tunnel mouth keeps its lintel.
@export var roof_span_dry := PackedFloat32Array([4.0, 6.0, 20.0, 20.0])
@export var roof_span_saturated := PackedFloat32Array([1.5, 2.0, 20.0, 20.0])
## Steepest face the solid holds, dry and saturated: the simulation fails a steeper face toward disturbed
## ground into loose (sim.glsl's slope stability; rock never). Dirt's dry slope is 45°, under the research
## doc's 60°, so a hole dug at 1 m cells caves around its third scoop in one spot (60° stands a wall 1.7 m
## over the next cell); this one number sets how a hole looks.
@export var stable_slope_dry := PackedFloat32Array([45.0, 70.0, 90.0, 90.0])
@export var stable_slope_saturated := PackedFloat32Array([35.0, 30.0, 90.0, 90.0])
## Servin compression index.
@export var compression_index := PackedFloat32Array([0.05, 0.5, 0.005, 0.005])
