# Contact Solvers: Unity (PhysX) vs Jolt

Both engines solve contacts the same basic way: an iterative impulse solver from the
Gauss-Seidel family, which pushes on one contact at a time and repeats several passes until
things settle. They differ in **how they fix overlap** between objects and **how they model
friction**. For this demo those details only matter once a box touches something.

See also [godot-port-feasibility.md](godot-port-feasibility.md).

## The shared pipeline

1. **Find candidate pairs.** A cheap bounding-box check finds which objects might be touching.
2. **Generate contacts.** For each pair, compute up to about 4 contact points, each with a
   normal and a penetration depth. Contacts are created slightly before objects actually
   touch, so a fast object can be caught before it passes through (a speculative contact).
3. **Solve.** For each contact, compute an impulse that stops the objects moving into each
   other and applies friction. Sweep through all contacts several times, each pass refining
   the last. Both engines start from the previous frame's impulses (warm starting), so a
   resting stack doesn't have to settle again every frame.
4. **Integrate.** Update velocities and positions.

## Unity (PhysX), as this project is configured

Values read from `ProjectSettings/DynamicsManager.asset`.

- **Solver:** Projected Gauss-Seidel (PGS), with 6 position iterations and 1 velocity
  iteration.
  - The **position iterations** solve velocities with an extra "bias" that pushes
    overlapping objects apart, capped by `maxDepenetrationVelocity` (10 m/s). Positions are
    advanced using these biased velocities.
  - The **velocity iteration** then solves again without the bias, so the push-apart speed
    isn't left in the object's final velocity. Without that, objects would gain bounce from
    penetration correction.
  - Unity also offers **Temporal Gauss-Seidel** (TGS), which moves positions forward between
    iterations and updates the contact geometry as it goes. It's better for stacks,
    heavy-on-light objects and joints.
- **Contacts:** created within `contactOffset` (0.01 m). The boxes use speculative collision
  detection, which widens that margin by how far the object moves in one step.
- **Friction:** this project uses **One Directional** friction, not Unity's default
  **Patch** friction (probably inherited from the 2019 project).
  - Patch friction treats each contact area as one patch, with friction in two directions.
  - One Directional applies friction only along the direction of sliding. It's cheaper, but
    less accurate when an object spins or slides sideways while sliding.
- **Bounce and sleep:** no bounce below 2 m/s of impact speed. Bodies sleep below a
  kinetic-energy threshold of 0.005.

## Jolt (Godot 4.6+)

Jolt's library defaults as understood at the time of writing; not yet checked in Godot.

- **Solver:** sequential impulses, in the style of Box2D, with two separate phases.
  - **Velocity steps** (default 10) solve contacts and friction with **no** push-apart bias.
    The only special case is speculative contacts, which may close their remaining gap
    during the step.
  - Positions are then integrated.
  - **Position steps** (default 2) fix overlap by **moving positions directly**, correcting
    20% of the overlap per step and ignoring overlap under 0.02 m. Because this never
    touches velocity, it can't add energy.

  Where PhysX separates "push apart" from "final velocity" by solving velocity twice, Jolt
  separates them by fixing position in its own pass. Jolt's approach is generally steadier
  for resting contact, with less jitter and less creeping energy.
- **Contacts:** speculative contacts are always on, out to 0.02 m. Fast objects can
  optionally use a continuous sweep (linear cast).
- **Friction:** each contact point gets friction along two perpendicular directions. The
  combined friction is limited to a circle bounded by friction coefficient × that point's
  normal impulse, which is closer to real Coulomb friction than PhysX's One Directional
  model.
- **Bounce and sleep:** no bounce below 1 m/s. A body sleeps when every point on it has moved
  slower than 0.03 m/s for 0.5 s.
- **Triangle-mesh edges:** an "enhanced internal edge removal" option stops objects catching
  on the seams between flat faces. PhysX does something similar when it prepares the mesh,
  by precomputing which edges are real. That matters for boxes sliding across the
  cylinder's 79 m flat sides.

## What this means for a Godot port

- **Falling and Coriolis drift won't change.** No contact solver runs while a box is in the
  air. Both engines advance motion the same way (semi-implicit Euler), so the 10 m drop
  result differs only by Godot's 60 Hz step versus Unity's 50 Hz.
- **Behaviour after landing will change:** how much a box bounces, how far it slides and
  tumbles, and how it settles. Jolt's position-based overlap fixing and its more accurate
  friction should make boxes settle more cleanly. The difference from today's One
  Directional friction is the most likely thing to notice.
- **Resting under the custom outward force works the same in both.** Each engine treats it
  like gravity. In both, applying a force every step likely keeps bodies from sleeping. With
  dozens of boxes that's fine; with thousands, skip applying the force to boxes that are
  already resting.
- **The player doesn't go through the contact solver in Godot.** `CharacterBody3D` is moved
  by collision queries (`move_and_slide`), not by impulses, so the player's feel comes from
  the movement code rather than from friction.

For a fairer comparison before porting, switch Unity to **Patch** friction (and optionally
TGS) first. Unity's behaviour then becomes the reference the Jolt version should roughly
match.
