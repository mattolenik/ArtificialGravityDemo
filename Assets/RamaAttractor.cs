using System;
using System.Collections.Generic;
using UnityEngine;

public class RamaAttractor : MonoBehaviour
{
    public enum Axes
    {
        Custom, Up, Right, Forward
    }

    public float Acceleration = 9.80665f;

    public Func<Vector3> Axis;

    public Axes AxisDirection;

    readonly List<RamaBody> capturedBodies = new List<RamaBody>();

    Ray axisRay;

    void Awake()
    {
        switch (AxisDirection)
        {
            case Axes.Up:
                Axis = () => transform.up;
                break;
            case Axes.Right:
                Axis = () => transform.right;
                break;
            case Axes.Forward:
                Axis = () => transform.forward;
                break;
        }
    }

    public void Capture(RamaBody body)
    {
        capturedBodies.Add(body);
    }

    public void Release(RamaBody body)
    {
        capturedBodies.Remove(body);
    }

    void FixedUpdate()
    {
        axis = Axis();
        axisRay = new Ray(transform.position, axis);
        foreach (var body in capturedBodies)
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
    // The point on the axis, directly above the body, which the body is attracted to
    Vector3 attractPoint;

    void Attract(RamaBody body)
    {
        hyp = transform.position - body.Body.position;
        dot = Vector3.Dot(axis, hyp.normalized);
        adj = hyp.magnitude * dot * -1;
        attractPoint = axisRay.GetPoint(adj);
        body.Down = (body.Body.position - attractPoint).normalized;
        body.Body.AddForce(body.Down * Acceleration, ForceMode.Acceleration);
        Debug.DrawLine(body.Body.position, attractPoint, Color.blue);
        Debug.DrawLine(transform.position, attractPoint, Color.red);
        Debug.DrawRay(body.Body.position, hyp, Color.yellow);
    }
}