// Lighting by the bar on the axis (light_bar.gd): a line source, so light arrives along the radial from
// straight overhead, inside the bar's lit arc only. Include after `varying vec2 theta_z` (the fragment's
// station-local theta and z) and set `bar_up` in vertex() to the view-space direction from the vertex
// toward the axis. The directional light that drives this reaches only the terrain's render layer.

// Angle around the axis the lit arc is centred on.
global uniform float light_bar_theta;
// cos of the arc's outer and inner edge half-angles: the dusk band lies between them.
global uniform vec2 light_bar_edge;

varying vec3 bar_up;

void light() {
	if (LIGHT_IS_DIRECTIONAL) {
		float day = smoothstep(light_bar_edge.x, light_bar_edge.y, cos(theta_z.x - light_bar_theta));
		DIFFUSE_LIGHT += day * clamp(dot(NORMAL, normalize(bar_up)), 0.0, 1.0) * ATTENUATION * LIGHT_COLOR;
	} else {
		// The headlamp (the tunnels design): an ordinary light.
		DIFFUSE_LIGHT += clamp(dot(NORMAL, LIGHT), 0.0, 1.0) * ATTENUATION * LIGHT_COLOR;
	}
}
