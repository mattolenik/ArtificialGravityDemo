## The tunables of the slice 3 tools and of the loose-dirt and water simulation (the terrain slice 3 plan,
## decision 7). Terrain.tool_params holds one, a default one when unset. Material numbers (swell, repose,
## porosity, wetting distance) live in materials.tres, not here. Lengths in m, cells are 1 m cells.
class_name ToolParams
extends Resource

## The bore disc's radius in cells (1: five cells, about 2 m across).
@export var bore_radius := 1
## How far each bore tick lowers the surface, in m (10 m in 30 s at bore_rate).
@export var bore_step := 1.0 / 30.0
## Bore ticks per second.
@export var bore_rate := 10.0
## The depth in m at which the auger stops.
@export var bore_depth := 10.0
## The spoil disc's radius in cells (2: 13 cells).
@export var spoil_radius := 2
## Cells from the auger's axis to the spoil disc's centre (decision 6).
@export var spoil_offset := 7
## Water the auger pumps, in m³ per second.
@export var pump_rate := 1.0
## How far ahead the crosshair may place the auger, in m.
@export var place_reach := 10.0
## How close the player must be to pick the auger up, in m.
@export var pickup_distance := 3.0
## What one shovel scoop takes, in m³ of loose dirt (solid ground counts times the swell).
@export var scoop_volume := 2.5
## The scoop's disc radius in cells (1: the five-cell plus, like the bore).
@export var scoop_radius := 1
## How far from the player the crosshair may scoop or dump, in m (4: a roof overhead is in reach).
@export var shovel_reach := 4.0
## The radius in m of the ball the shovel scoops and dumps in the voxel box (1.5 m by the user's choice on
## 2026-11-04, over the design's 1: a scoop takes a half ball, about 9 m³; at 2 m no roofed tunnel can start
## sideways from a pit under dirt's free height (4 m then, 5 m now)).
@export var scoop_ball := 1.5
## Seconds between scoops while T is held.
@export var scoop_interval := 0.25
## The feet's disc radius in cells (1: a five-cell plus).
@export var foot_radius := 1
## Compaction a landing adds to loose cells; at 1 the cell folds into the solid surface.
@export var tamp_step := 0.25
## The slowest downward landing speed that tamps, in m/s.
@export var tamp_land_speed := 2.0
## The share of the excess over repose a slump step moves.
@export var slump_rate := 0.125
## The share of a water surface difference a flow step moves.
@export var flow_rate := 0.125
## The share of a cell's loose that flowing water carries per step, at full transport_depth outflow.
@export var transport_share := 0.1
## The water outflow in m at which transport is full.
@export var transport_depth := 0.05
## Simulation steps between soak and wetting ticks (6: 10 Hz at 60 steps a second).
@export var soak_every := 6
## The depth of the column that holds pore water, in m (capacity = porosity · soak_column).
@export var soak_column := 0.5
## Seconds a tile must stay still before it is packed and leaves the active set.
@export var settle_time := 1.0
## The smallest change in m that keeps a tile active.
@export var move_eps := 1e-4
## The shortest time between edit-shape rebakes for tool touches inside the zone, in s.
@export var collider_edit_interval := 0.2
## The shortest time between collider zone moves for tool touches, in s.
@export var collider_zone_interval := 1.0
