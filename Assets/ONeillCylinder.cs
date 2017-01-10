using System;
using System.Collections.Generic;
using UnityEngine;

[AddComponentMenu("Physics/ONeill Cylinder")]
[RequireComponent(typeof(MeshFilter))]
public class ONeillCylinder : MonoBehaviour
{
    public float Acceleration = 9.8f;

    public Vector3 Rotation = new Vector3(0f, 0f, 0.05f);

    float radius;

    readonly HashSet<CapturedBody> capturedBodies = new HashSet<CapturedBody>();

    Ray axisRay;

    public void Capture(CapturedBody body)
    {
        capturedBodies.Add(body);
    }

    public void Release(CapturedBody body)
    {
        capturedBodies.Remove(body);
    }

    void Start()
    {
        axis = transform.forward;
        axisRay = new Ray
        {
            origin = transform.position,
            direction = axis
        };
        var mesh = GetComponent<MeshFilter>().mesh;
        // Assuming the mesh is perfect cylinder on the outside,
        // the bounds would read (radius, radius, length)
        radius = mesh.bounds.max.x;
    }

    void FixedUpdate()
    {
        transform.Rotate(Rotation, Space.Self);
        foreach(var body in capturedBodies)
        {
            Attract(body);
        }
    }

    // Axis of the attractor, perpendicular to the direction of gravity
    Vector3 axis;
    // Hypotenous between body and attractor
    Vector3 hyp;
    // Dot product of axis and hyp
    float dot;
    // Length of edge adjacent to hypotenous, parallel to axis
    float adj;
    // Direction of "gravity"
    Vector3 gravity;

    void Attract(CapturedBody body)
    {
        hyp = transform.position - body.Body.position;
        dot = Vector3.Dot(axis, hyp.normalized);
        adj = hyp.magnitude * dot * -1;
        // Radial distance from axis to body
        var r = body.Body.position - axisRay.GetPoint(adj);
        gravity = r.normalized;
        body.Gravity = gravity;
        // Approximate 10% deadzone in center
        if (r.magnitude < radius * 0.10f)
        {
            //return;
        }
        var a = Acceleration;// / r.sqrMagnitude;
        body.Body.AddForce(body.Gravity * a, ForceMode.Acceleration);
    }
}