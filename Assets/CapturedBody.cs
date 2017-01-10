using UnityEngine;

[AddComponentMenu("Physics/Captured Body")]
[RequireComponent(typeof(Rigidbody))]
public class CapturedBody : MonoBehaviour
{
    ONeillCylinder attractor;

    public Rigidbody Body { get; private set; }

    public Vector3 Down
    {
        get { return down; }
        set { down = value; up = value * -1; }
    }

    public Vector3 Up
    {
        get { return up; }
    }

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

    Vector3 up;
    Vector3 down;

    void Awake()
    {
        attractor = GetComponentInParent<ONeillCylinder>();
        Body = GetComponent<Rigidbody>();
        attractor.Capture(this);
    }
}