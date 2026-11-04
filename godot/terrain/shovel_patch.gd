## The shovel's patch (the tunnels design): a ring decal the ball's width across, projected along the surface
## normal at the crosshair's hit while one is in reach, onto the terrain meshes only.
class_name ShovelPatch
extends Decal

const SIZE := 2.0
const PIXELS := 64


func _ready() -> void:
	var img := Image.create(PIXELS, PIXELS, false, Image.FORMAT_RGBA8)
	for y in PIXELS:
		for x in PIXELS:
			var r := Vector2(x + 0.5, y + 0.5).distance_to(Vector2.ONE * PIXELS / 2.0) / (PIXELS / 2.0)
			img.set_pixel(x, y, Color(1.0, 0.9, 0.2, 1.0 if r >= 0.8 and r <= 1.0 else 0.0))
	texture_albedo = ImageTexture.create_from_image(img)
	size = Vector3(SIZE, 1.0, SIZE)
	cull_mask = Terrain.RENDER_LAYER
	visible = false


## Shows the ring at station-local p, its face along the normal n, radius m across each way.
func show_at(p: Vector3, n: Vector3, station: Node3D, radius := SIZE / 2.0) -> void:
	if size.x != 2.0 * radius:
		size = Vector3(2.0 * radius, 1.0, 2.0 * radius)
	var y := n.normalized()
	var x := y.cross(Vector3.FORWARD)
	if x.length() < 1e-3:
		x = y.cross(Vector3.RIGHT)
	x = x.normalized()
	global_transform = station.global_transform * Transform3D(Basis(x, y, x.cross(y)), p)
	visible = true
