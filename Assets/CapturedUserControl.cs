using UnityEngine;
using UnityStandardAssets.CrossPlatformInput;

[RequireComponent(typeof(CapturedRigidbodyController))]
public class CapturedUserControl : MonoBehaviour
{
    float angle;
    float right;
    float forward;
    bool jumping;
    CapturedBody body;
    CapturedRigidbodyController controller;

    void Awake()
    {
        body = GetComponent<CapturedBody>();
        controller = GetComponent<CapturedRigidbodyController>();
    }

    void Update()
    {
        angle = CrossPlatformInputManager.GetAxis("Mouse X") * 2f;
        right = Input.GetAxis("Horizontal");
        forward = Input.GetAxis("Vertical");
        jumping = Input.GetButton("Jump");
    }

    void FixedUpdate()
    {
        // Rotate body around local Z axis according to mouse left/right movement
        transform.localRotation *= Quaternion.AngleAxis(angle, Vector3.up);
        controller.Move(forward, right, jumping);
    }
}