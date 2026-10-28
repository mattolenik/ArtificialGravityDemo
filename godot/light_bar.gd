## A bar of white light along the station's axis, turning with the station but a little slower, so in
## the station's frame (the scene) its lit arc drifts anti-spinward once per day_length: day under the
## arc, night elsewhere, with a long soft terminator between (soft_deg each side of the arc's edge). The
## bar itself is an unshaded white cylinder. Its light is a line source, so every lit
## point is lit from straight overhead; the terrain shaders apply the arc per fragment from the global
## shader parameters set here (light_bar.gdshaderinc), fed by a directional light that reaches only the
## terrain's render layer, while a second directional light for everything else points down the radial
## at the current camera and is dimmed by the arc there. Place it under the Station at its origin.
class_name LightBar
extends Node3D

@export var station: Station
## Width of the lit arc around the axis, degrees, measured at half brightness.
@export_range(0, 360) var arc_deg := 160.0
## Half-width of the dawn and dusk bands, degrees: full day soft_deg inside the arc's edge, full night
## soft_deg outside it.
@export_range(0, 90) var soft_deg := 30.0
## Seconds of real time for the lit arc to go once around the station: one day and night.
@export_range(1, 86400, 1, "or_greater") var day_length := 600.0
## Radius of the bar, m.
@export var radius := 20.0

## Angle around the axis (theta, as Cyl) the lit arc is centred on, rad.
var theta := 0.0

var _sun := DirectionalLight3D.new()
var _terrain_sun := DirectionalLight3D.new()


func _ready() -> void:
	# Children are ready before their parent, so the station may not have measured its hull yet.
	if station.radius == 0.0:
		await station.ready
	var mesh := CylinderMesh.new()
	mesh.top_radius = radius
	mesh.bottom_radius = radius
	mesh.height = station.length
	var white := StandardMaterial3D.new()
	white.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	white.albedo_color = Color.WHITE
	mesh.material = white
	var bar := MeshInstance3D.new()
	bar.mesh = mesh
	bar.rotation.x = PI / 2  # a CylinderMesh stands along Y; the axis is Z
	add_child(bar)
	_terrain_sun.light_cull_mask = Terrain.RENDER_LAYER
	_sun.light_cull_mask = 0xFFFFFFFF & ~Terrain.RENDER_LAYER
	add_child(_sun)
	add_child(_terrain_sun)
	var half := deg_to_rad(arc_deg / 2.0)
	var soft := deg_to_rad(soft_deg)
	RenderingServer.global_shader_parameter_set("light_bar_edge", Vector2(cos(half + soft), cos(half - soft)))


## 1 inside the lit arc of arc_deg centred on bar_theta, 0 outside, blending across soft_deg at the edges.
static func day(at_theta: float, bar_theta: float, arc_deg: float, soft_deg: float) -> float:
	var half := deg_to_rad(arc_deg / 2.0)
	var soft := deg_to_rad(soft_deg)
	return smoothstep(cos(half + soft), cos(half - soft), cos(at_theta - bar_theta))


func _process(delta: float) -> void:
	# The bar turns spinward with the station, short of it by one turn per day_length.
	theta = wrapf(theta - TAU / day_length * delta, 0.0, TAU)
	RenderingServer.global_shader_parameter_set("light_bar_theta", theta)
	var cam := get_viewport().get_camera_3d()
	if cam == null:
		return
	var down := station.down_at(cam.global_position)
	if down != Vector3.ZERO:
		var basis := Basis.looking_at(down, (station.global_basis * station.axis).normalized())
		_sun.global_basis = basis
		_terrain_sun.global_basis = basis
	_sun.light_energy = day(Cyl.theta_of(station.to_local(cam.global_position)), theta, arc_deg, soft_deg)
