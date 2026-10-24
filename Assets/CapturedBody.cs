using UnityEngine;

/// <summary>
/// Captures rigidbodies into the "gravity" well of the cylinder
/// </summary>
[AddComponentMenu("Physics/Captured Body")]
[RequireComponent(typeof(Rigidbody))]
public class CapturedBody : MonoBehaviour
{
    ONeillCylinder attractor;

    [Tooltip("Drag coefficient × frontal area (m²). About 0.26 for a 0.5 m cube, 0.8 for a standing person. 0 disables air drag.")]
    public float DragArea;

    public Vector3 Position
    {
        get { return Body.position; }
        set { Body.position = value; }
    }

    public Rigidbody Body { get; private set; }

    public Vector3 Gravity { get; set; }

    public void AddForce(Vector3 force)
    {
        Body.AddForce(force);
    }

    public bool FreezeRotation
    {
        get { return Body.freezeRotation; }
        set { Body.freezeRotation = value; }
    }

    public Vector3 Velocity
    {
        get { return Body.linearVelocity; }
    }

    void Awake()
    {
        attractor = FindAnyObjectByType<ONeillCylinder>();
        Body = GetComponent<Rigidbody>();
        attractor.Capture(this);
    }
}