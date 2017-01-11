using UnityEngine;

/// <summary>
/// Captures rigidbodies into the "gravity" well of the cylinder
/// </summary>
[AddComponentMenu("Physics/Captured Body")]
[RequireComponent(typeof(Rigidbody))]
public class CapturedBody : MonoBehaviour
{
    ONeillCylinder attractor;

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
        get { return Body.velocity; }
    }

    void Awake()
    {
        attractor = GetComponentInParent<ONeillCylinder>();
        Body = GetComponent<Rigidbody>();
        attractor.Capture(this);
    }
}