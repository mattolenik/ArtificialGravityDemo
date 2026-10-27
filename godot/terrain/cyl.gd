## Coordinates on the inside of the cylinder, in station space: the spin axis is +Z, theta is 0
## at local -Y (straight below the axis) and grows spinward (+X at the bottom), and height h is
## measured from the hull toward the axis, so the radius from the axis is R - h.
class_name Cyl


## Station-space point at angle theta, axial position z and height h above the hull.
static func position(theta: float, z: float, h: float, R: float) -> Vector3:
	return Vector3((R - h) * sin(theta), -(R - h) * cos(theta), z)


## Angle of p around the axis, in [0, TAU).
static func theta_of(p: Vector3) -> float:
	return fposmod(atan2(p.x, -p.y), TAU)


## Height of p above the hull.
static func height_of(p: Vector3, R: float) -> float:
	return R - sqrt(p.x * p.x + p.y * p.y)


## Volume between heights h1 <= h2 over a dtheta by dz patch: the annulus sector's area times dz.
static func span_volume(h1: float, h2: float, R: float, dtheta: float, dz: float) -> float:
	return dtheta * dz * ((R - h1) * (R - h1) - (R - h2) * (R - h2)) / 2.0


## CPU reference for the collider bake. h[k] is the surface height at angle
## (k - (h.size() - 1) / 2) * dtheta. Each sample maps to the flat chart (x, y) =
## ((R - h) sin phi, R - (R - h) cos phi); the result is y at x_i = (i - (n_out - 1) / 2) * spacing,
## interpolated along the polyline of mapped samples. Where the polyline folds back (x decreasing),
## several segments cover an x and the highest y wins. An x past either end clamps to the nearest sample.
static func bake_row(h: PackedFloat32Array, dtheta: float, R: float, spacing: float, n_out: int) -> PackedFloat32Array:
	var n := h.size()
	var xs := PackedFloat64Array()
	var ys := PackedFloat64Array()
	xs.resize(n)
	ys.resize(n)
	for k in n:
		var phi := (k - (n - 1) / 2.0) * dtheta
		xs[k] = (R - h[k]) * sin(phi)
		ys[k] = R - (R - h[k]) * cos(phi)
	var out := PackedFloat32Array()
	out.resize(n_out)
	for i in n_out:
		var x := (i - (n_out - 1) / 2.0) * spacing
		var best := -INF
		for k in n - 1:
			var x0 := xs[k]
			var x1 := xs[k + 1]
			if x < minf(x0, x1) or x > maxf(x0, x1):
				continue
			# A vertical segment covers its x with both endpoints.
			var y := maxf(ys[k], ys[k + 1]) if x0 == x1 else lerpf(ys[k], ys[k + 1], (x - x0) / (x1 - x0))
			best = maxf(best, y)
		if best == -INF:
			var nearest := INF
			for k in n:
				if absf(xs[k] - x) < nearest:
					nearest = absf(xs[k] - x)
					best = ys[k]
		out[i] = best
	return out
