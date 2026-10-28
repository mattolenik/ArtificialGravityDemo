## Every knob of a generated world, plus the grid sizes derived from the geometry. Saved with the
## world, so a world file reproduces itself regardless of later changes to the defaults.
class_name WorldParams
extends Resource

@export var seed: int = 1
## Hull radius in m, and axial length in m.
@export var radius: float = 3200
@export var length: float = 32000
## Gravity at the hull in m/s^2.
@export var g_hull: float = 9.8
## Datum: height of sea level above the hull, in m.
@export var h_sea: float = 400
## Terrain relief is defined as h_ref metres on a world with gravity g_ref (scaled by g_sea).
@export var h_ref: float = 1000
@export var g_ref: float = 9.8
## Macro grid cell size in m.
@export var macro_cell: float = 32
@export var sea_z: float = 0
@export var sea_width: float = 3000
@export var sea_edge_noise: float = 600
@export var sea_depth_max: float = 400
@export var island_count: int = 6
@export var region_scale: float = 4000
@export var river_sources_per_km2: float = 0.08
@export var river_q_min: float = 2.0
@export var lake_rate: float = 0.33
@export var cliff_min: float = 10
@export var cliff_max: float = 60
@export var cliff_fraction: float = 0.15
@export var bank_distance: float = 10
@export var bank_slope_deg: float = 35
## Bedrock depth below the surface in m, [min, max] per region.
@export var bedrock_depth: Dictionary = {"flat": [150, 300], "hill": [60, 150], "mountain": [0, 40]}
@export var clay_thickness: Vector2 = Vector2(2, 10)
@export var clay_fraction: float = 0.2
@export var spawn_max_slope_deg: float = 5
@export var spawn_river_distance: float = 100
## Detail noise: relative weight of the 32, 16, 8, 4, 2 and 1 m octaves, normalised by their sum; 0 drops
## one. The weights are non-negative (a mixed-sign list whose sum is at or below 0 divides by 1e-6 in the
## shader). Under 4 cells an octave is per-cell noise, so the 1 m window's 2 m and 1 m are off.
@export var detail_octaves: PackedFloat32Array = PackedFloat32Array([1.0, 0.5, 0.25, 0.125, 0.0, 0.0])
## Detail noise peak in m by region id: sea, flat, hill, mountain, island.
@export var detail_region_amp: PackedFloat32Array = PackedFloat32Array([1.5, 1.5, 4.0, 8.0, 4.0])
## Bare rock's detail amplitude is 1 + this times its region's, fading in over the last 1 m of cover.
@export var detail_rock_roughness: float = 2.0


## Samples around the sea-level circumference at about 1 m, as a power of two so tiles divide it.
func n_theta() -> int:
	return 2 ** roundi(log(TAU * (radius - h_sea)) / log(2.0))


## Samples along the axis at 1 m, rounded down to a multiple of 128.
func n_z() -> int:
	return floori(roundi(length) / 128.0) * 128


func macro_w() -> int:
	return floori(n_theta() / 32.0)


func macro_h() -> int:
	return floori(n_z() / 32.0)


## Gravity at sea level in m/s^2.
func g_sea() -> float:
	return g_hull * (radius - h_sea) / radius


## Mountain height in m: h_ref on a g_ref world, scaled to the gravity at sea level.
func h_mtn() -> float:
	return h_ref * g_ref / g_sea()


## Angle between neighbouring samples around the sea-level circumference.
func dtheta() -> float:
	return TAU / n_theta()


## The 1 m cell (theta index, z index) of station-local (theta, z). Theta wraps; the posmod also
## guards an angle a hair under TAU whose division by dtheta() rounds up to n_theta(). Z counts from
## -length / 2 and is not clamped.
func cell_of(theta: float, z: float) -> Vector2i:
	return Vector2i(posmod(floori(theta / dtheta()), n_theta()), floori(z + length / 2.0))
