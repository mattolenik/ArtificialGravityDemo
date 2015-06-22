using System;
using UnityEngine;
using UnityStandardAssets.CrossPlatformInput;

[Serializable]
public class RamaMouseLook
{
    public float XSensitivity = 2f;
    public float YSensitivity = 2f;
    public bool clampVerticalRotation = false;
    public float MinimumX = -90F;
    public float MaximumX = 90F;
    public bool smooth;
    public float smoothTime = 15f;


    Quaternion m_CharacterTargetRot;
    Quaternion m_CameraTargetRot;


    public void Init(Transform character, Transform camera)
    {
        m_CharacterTargetRot = character.localRotation;
        m_CameraTargetRot = camera.localRotation;
    }

    public void LookRotation(Transform character, Transform camera, Vector3 up)
    {
        float yRot = CrossPlatformInputManager.GetAxis("Mouse X") * XSensitivity;
        float xRot = CrossPlatformInputManager.GetAxis("Mouse Y") * YSensitivity;

        var right = Vector3.Cross(up, character.forward);
        var upQ = Quaternion.AngleAxis(-MaximumX, right);
        var downQ = Quaternion.AngleAxis(-MinimumX, right);
        Debug.DrawRay(character.position, right, Color.magenta);

        m_CameraTargetRot = xRot > 0 ?
            Quaternion.RotateTowards(camera.localRotation, upQ, xRot * Time.deltaTime * 100) :
            Quaternion.RotateTowards(camera.localRotation, downQ, -xRot * Time.deltaTime * 100);

        if (clampVerticalRotation)
        {
        }

        if (smooth)
        {
            camera.localRotation = Quaternion.Slerp(camera.localRotation, m_CameraTargetRot,
                smoothTime * Time.deltaTime);
        }
        else
        {
            camera.localRotation = m_CameraTargetRot;
        }
    }
}