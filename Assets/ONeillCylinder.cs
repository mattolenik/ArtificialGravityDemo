using System;
using System.Collections.Generic;
using System.Linq;
using UnityEngine;

/// <summary>
/// Simulates artificial gravity by applying a force downward from the axis of rotation
/// towards the rigidbody.
/// </summary>
[AddComponentMenu("Physics/ONeill Cylinder")]
[RequireComponent(typeof(MeshFilter))]
public class ONeillCylinder : MonoBehaviour
{
    public float Acceleration = 9.8f;

    [Tooltip("Rotation vector that the station should spin about.")]
    public Vector3 Rotation = new Vector3(0f, 0f, 0.05f);

    [Tooltip("Create a deadzone in the center with no gravity, with a radius this multipler times of the radius of the cylinder.")]
    public float DeadzonePercent = 0.05f;

    [Tooltip("Gravity decreases by this power as bodies move closer to the center. Should be 2 or 3.")]
    public int GravityFalloffPower = 3;

    float radius;

    readonly HashSet<CapturedBody> bodySet = new HashSet<CapturedBody>();

    CapturedBody[] bodyArray;

    public void Capture(params CapturedBody[] bodies)
    {
        for(var i = 0; i < bodies.Length; i++)
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
        transform.Rotate(Rotation, Space.Self);
        for (var i = 0; i < bodyArray.Length; i++)
        {
            Attract(bodyArray[i]);
        }
    }

    void Attract(CapturedBody body)
    {
        var r = Vector3.Project(body.Position - transform.position, Rotation.normalized);
        var bodyToCenter = (body.Position - r);
        var distance = bodyToCenter.magnitude;
        var f = distance/radius;
        body.Gravity = bodyToCenter.normalized * Mathf.Pow(f, GravityFalloffPower);
        //Debug.Log(f);
        //Debug.DrawLine(body.Position, r, Color.red);
        // Approximate 5% deadzone in center
        if (distance < radius * DeadzonePercent)
        {
            //return;
        }
        var a = Acceleration;// / r.sqrMagnitude;
        body.Body.AddForce(body.Gravity * a, ForceMode.Acceleration);
    }
}