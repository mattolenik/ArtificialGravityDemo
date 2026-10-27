## The 32 m maps and vector data the generator produces, indexed by (theta cell, z cell). Cell i
## covers [i, i + 1) cells with its centre at i + 0.5; theta wraps, z is clamped.
class_name MacroMaps
extends Resource

## Heights in m (FORMAT_RF, macro_w x macro_h).
@export var surface: Image
@export var bedrock_top: Image
@export var clay_bottom: Image
@export var clay_top: Image
@export var water_surface: Image
## 0 sea, 1 flat, 2 hill, 3 mountain, 4 island (FORMAT_R8).
@export var region: Image
## 255 in a cliff band (FORMAT_R8).
@export var cliff: Image
## 0 none, 1..8 the neighbour index (FORMAT_R8).
@export var flow_dir: Image
## Distance to the nearest river centreline in m, that river's width in m, its surface height in m (FORMAT_RGBF).
@export var river: Image
## Each flattened [theta, z, width, Q, theta, z, width, Q, ...] from source to mouth.
@export var rivers: Array[PackedFloat32Array] = []
## {"theta", "z", "radius", "level"}
@export var lakes: Array[Dictionary] = []
## {"intake": Vector2, "outlets": PackedVector2Array, "q": float}
@export var loops: Array[Dictionary] = []
## Spawn point as (theta, z).
@export var spawn: Vector2


## Bilinear sample of a FORMAT_RF image at (theta, z). Wraps theta, clamps z.
func sample(img: Image, theta: float, z: float, params: WorldParams) -> float:
	var w := params.macro_w()
	var x := theta / (params.dtheta() * 32.0) - 0.5
	var y := clampf((z + params.length / 2.0) / params.macro_cell - 0.5, 0.0, params.macro_h() - 1.0)
	var x0 := floori(x)
	var y0 := floori(y)
	var y1 := mini(y0 + 1, params.macro_h() - 1)
	var fx := x - x0
	var fy := y - y0
	var i0 := posmod(x0, w)
	var i1 := posmod(x0 + 1, w)
	var top := lerpf(img.get_pixel(i0, y0).r, img.get_pixel(i1, y0).r, fx)
	var bottom := lerpf(img.get_pixel(i0, y1).r, img.get_pixel(i1, y1).r, fx)
	return lerpf(top, bottom, fy)


## The macro cell containing (theta, z).
func cell(theta: float, z: float, params: WorldParams) -> Vector2i:
	return Vector2i(
		posmod(floori(theta / (params.dtheta() * 32.0)), params.macro_w()),
		clampi(floori((z + params.length / 2.0) / params.macro_cell), 0, params.macro_h() - 1))
