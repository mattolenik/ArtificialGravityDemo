using UnityEngine;

[RequireComponent(typeof(Rigidbody))]
public class RamaBody : MonoBehaviour
{
    public RamaAttractor Attractor;

    // Automatically capture to Attractor on startup.
    public bool AutoCapture = true;

    public Rigidbody Body { get; private set; }

    public Vector3 Down { get; set; }
    public Vector3 Up { get { return Down * -1; } }

    void Start()
    {
        Body = GetComponent<Rigidbody>();
        if (AutoCapture)
        {
            Attractor.Capture(this);
        }
    }
}