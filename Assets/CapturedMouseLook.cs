using UnityEngine;
using UnityStandardAssets.CrossPlatformInput;

public class CapturedMouseLook : MonoBehaviour
{
    float angle;
    float input;
    CapturedBody body;

    void Awake()
    {
        body = GetComponent<CapturedBody>();
    }

    void Update()
    {
        input = CrossPlatformInputManager.GetAxis("Mouse X") * 2f;
    }

    void FixedUpdate()
    {
        // Rotate body around local Z axis according to mouse left/right movement
        // Implements character turning.
        angle += input;
        var rot = Quaternion.AngleAxis(angle, Vector3.up);
        transform.rotation = Quaternion.LookRotation(Vector3.forward, body.Up);
        transform.localRotation *= rot;
    }
}
