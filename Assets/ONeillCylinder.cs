using System;
using System.Collections.Generic;
using System.Linq;
using UnityEngine;

/// <summary>
/// Simulates artificial gravity in a spinning cylinder. The cylinder itself stays still and
/// the scene is simulated in its rotating frame, where Newton's laws gain two fictitious
/// forces: centrifugal (ω²r, outward) and Coriolis (−2Ω×v). Both are exact, not approximations.
/// </summary>
[AddComponentMenu("Physics/ONeill Cylinder")]
[RequireComponent(typeof(MeshCollider))]
[RequireComponent(typeof(MeshFilter))]
[RequireComponent(typeof(Rigidbody))]
public class ONeillCylinder : MonoBehaviour
{
    [Tooltip("Apparent gravity at the floor, in m/s². Sets the spin rate: ω = √(a / radius).")]
    public float Acceleration = 9.8f;

    [Tooltip("Local axis the station spins about (right-handed).")]
    public Vector3 Axis = Vector3.forward;

    [Tooltip("Air density at the floor, in kg/m³.")]
    public float AirDensity = 1.225f;

    [Tooltip("Air pressure at the floor, in Pa.")]
    public float AirPressure = 101325f;

    float radius;

    Vector3 omega;

    readonly HashSet<CapturedBody> bodySet = new HashSet<CapturedBody>();

    CapturedBody[] bodyArray;

    public void Capture(params CapturedBody[] bodies)
    {
        for (var i = 0; i < bodies.Length; i++)
        {
            bodySet.Add(bodies[i]);
        }
        // This only happens any time new rigidbodies are added to the scene.
        // The faster iteration over the array is worth the cost.
        bodyArray = bodySet.ToArray();
    }

    public void Release(params CapturedBody[] bodies)
    {
        for (var i = 0; i < bodies.Length; i++)
        {
            bodySet.Remove(bodies[i]);
        }
        bodyArray = bodySet.ToArray();
    }

    void Start()
    {
        var mesh = GetComponent<MeshFilter>().mesh;
        // Assuming the mesh is perfect cylinder on the outside,
        // the bounds would read (radius, radius, length)
        radius = mesh.bounds.max.x;
    }

    void FixedUpdate()
    {
        omega = transform.TransformDirection(Axis.normalized) * Mathf.Sqrt(Acceleration / radius);
        for (var i = 0; i < bodyArray.Length; i++)
        {
            Attract(bodyArray[i]);
        }
    }

    void Attract(CapturedBody body)
    {
        var offset = body.Position - transform.position;
        // Outward from the axis, i.e. "down" for anyone standing on the floor.
        var radial = Vector3.ProjectOnPlane(offset, omega);
        body.Gravity = radial.normalized;
        body.Body.AddForce(FictitiousAcceleration(offset, body.Velocity, omega), ForceMode.Acceleration);
        if (body.DragArea > 0f)
        {
            // The air co-rotates with the station, so it is at rest in this frame.
            var v = body.Velocity;
            var density = AirDensityAt(radial.magnitude, radius, omega.magnitude, AirDensity, AirPressure);
            body.Body.AddForce(-0.5f * density * body.DragArea * v.magnitude * v);
        }
    }

    /// <summary>
    /// Isothermal air density at distance <paramref name="r"/> from the axis: hydrostatic balance
    /// against the centrifugal potential. Only ~3% thinner at the axis of a 500 m, 1 g station.
    /// </summary>
    public static float AirDensityAt(float r, float radius, float omega, float floorDensity, float floorPressure)
    {
        return floorDensity * Mathf.Exp(-0.5f * omega * omega * (radius * radius - r * r) * floorDensity / floorPressure);
    }

    /// <summary>
    /// Acceleration of a free body in a frame spinning at <paramref name="omega"/> (rad/s),
    /// given its offset from a point on the axis and its velocity relative to the frame.
    /// </summary>
    public static Vector3 FictitiousAcceleration(Vector3 offset, Vector3 velocity, Vector3 omega)
    {
        var centrifugal = -Vector3.Cross(omega, Vector3.Cross(omega, offset));
        var coriolis = -2f * Vector3.Cross(omega, velocity);
        return centrifugal + coriolis;
    }
}
