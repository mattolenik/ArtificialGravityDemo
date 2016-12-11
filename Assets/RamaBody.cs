using UnityEngine;

[RequireComponent(typeof(Rigidbody))]
public class RamaBody : MonoBehaviour
{
    public RamaAttractor Attractor;

    // Automatically capture to Attractor on startup.
    public bool AutoCapture = true;

    public Rigidbody Body
    {
        get { return body ?? (body = GetComponent<Rigidbody>()); }
        private set { body = value;}
    }

    public Vector3 Down
    {
        get { return down; }
        set { down = value; up = value * -1; }
    }

    public Vector3 Up
    {
        get { return up; }
    }

    Vector3 up;
    Vector3 down;
    Rigidbody body;

    void Awake()
    {
        Body = GetComponent<Rigidbody>();
        if (AutoCapture)
        {
            Attractor.Capture(this);
        }
    }
}