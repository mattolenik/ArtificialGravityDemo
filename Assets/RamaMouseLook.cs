using System;
using UnityEngine;
using UnityStandardAssets.CrossPlatformInput;

public class RamaMouseLook : MonoBehaviour
{
    public float XSensitivity = 2f;
    public float YSensitivity = 2f;
    public bool ClampVerticalRotation = false;
    public float Minimum = -90F;
    public float Maximum = 90F;
    public bool Smooth;
    public float SmoothTime = 15f;
    public bool XAxis;
    public bool YAxis;

    void FixedUpdate()
    {
        if (XAxis)
        {
            Mouselook("Mouse X", Vector3.up, XSensitivity);
        }
        if (YAxis)
        {
            Mouselook("Mouse Y", Vector3.right, YSensitivity);
        }
    }

    void Mouselook(string inputAxis, Vector3 axis, float sensitivity)
    {
        var input = CrossPlatformInputManager.GetAxis(inputAxis) * sensitivity;

        var up = Quaternion.AngleAxis(-Maximum, axis);
        var down = Quaternion.AngleAxis(-Minimum, axis);

        var targetRotation = input > 0 ?
                    Quaternion.RotateTowards(transform.localRotation, up, input * Time.fixedDeltaTime * 100f) :
                    Quaternion.RotateTowards(transform.localRotation, down, -input * Time.fixedDeltaTime * 100f);

        if (Smooth)
        {
            transform.localRotation = Quaternion.Slerp(transform.localRotation, targetRotation,
                SmoothTime * Time.fixedDeltaTime);
        }
        else
        {
            transform.localRotation = targetRotation;
        }
    }
}