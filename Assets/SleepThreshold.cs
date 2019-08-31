using UnityEngine;

[AddComponentMenu("Physics/Object Sleep Threshold")]
[RequireComponent(typeof(Rigidbody))]
public class SleepThreshold : MonoBehaviour
{
    Rigidbody body;

    public float Threshold = 0.1f;

    void Awake()
    {
        body = GetComponent<Rigidbody>();
    }

    void FixedUpdate()
    {
        body.sleepThreshold = Threshold;
    }
}
