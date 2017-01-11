using UnityEngine;
using UnityStandardAssets.CrossPlatformInput;

[RequireComponent(typeof(CapturedRigidbodyController))]
public class CapturedUserControl : MonoBehaviour
{
    Camera cam;

    float angleX;
    float angleY;
    float right;
    float forward;
    bool jumping;
    CapturedBody body;
    CapturedRigidbodyController controller;

    void Start()
    {
        body = GetComponent<CapturedBody>();
        controller = GetComponent<CapturedRigidbodyController>();
        cam = Camera.main;
    }

    void Update()
    {
        angleX += CrossPlatformInputManager.GetAxis("Mouse X") * Mathf.Rad2Deg;
        angleY -= CrossPlatformInputManager.GetAxis("Mouse Y") * Mathf.Rad2Deg;
        right = Input.GetAxis("Horizontal");
        forward = Input.GetAxis("Vertical");
        jumping = Input.GetButton("Jump");
    }

    void FixedUpdate()
    {
        // Rotate body around local Z axis according to mouse left/right movement
        transform.localRotation = Quaternion.AngleAxis(angleX * Time.fixedDeltaTime, Vector3.up) * Quaternion.Euler(-body.Gravity);
        cam.transform.localRotation = Quaternion.AngleAxis(angleY * Time.fixedDeltaTime, Vector3.right);
        controller.Move(forward, right, jumping);
    }
}