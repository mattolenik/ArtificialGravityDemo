using System;
using System.Collections.Generic;
using System.Linq;
using UnityEngine;
using UnityStandardAssets.CrossPlatformInput;

[RequireComponent(typeof(Rigidbody))]
[RequireComponent(typeof(CapsuleCollider))]
public class RigidbodyController : MonoBehaviour
{
    public float Speed = 10.0f;

    public bool Oomph = true;

    public bool CanJump = true;
    
    public float JumpForce = 2.0f;

    public float JumpDelay = 2.0f;

    bool grounded;

    RamaBody rBody;

    TimeSpan jumpDelay;
    DateTime lastJump = DateTime.MinValue;
    float angle;

    void Awake()
    {
        rBody = gameObject.GetComponent<RamaBody>();
        rBody.Body.freezeRotation = true;
        jumpDelay = TimeSpan.FromSeconds(JumpDelay);
    }

    void FixedUpdate()
    {
        var input = CrossPlatformInputManager.GetAxis("Mouse X") * 2f;
        angle += input;
        var rot = Quaternion.AngleAxis(angle, Vector3.up);
        transform.rotation = Quaternion.LookRotation(Vector3.forward, rBody.Up);
        transform.localRotation *= rot;
        if (grounded)
        {
            var right = Input.GetAxis("Horizontal");
            var forward = Input.GetAxis("Vertical");
            var jumping = Input.GetButton("Jump") && DateTime.Now - lastJump > jumpDelay;

            var moveForce = (transform.forward * forward + transform.right * right) * Speed;
            moveForce = Vector3.ClampMagnitude(moveForce, Speed);
            if (jumping)
            {
                moveForce += rBody.Up * JumpForce;
                lastJump = DateTime.Now;
            }
            rBody.Body.AddForce(moveForce, ForceMode.Force);

            if (Oomph)
            {
                var oomphForce = 1f / Mathf.Pow(rBody.Body.velocity.magnitude, 2f);
                oomphForce = Mathf.Clamp(oomphForce, 0, Speed);
                Debug.Log(oomphForce);
                rBody.Body.AddForce(moveForce.normalized * oomphForce, ForceMode.Force);
            }
        }
        grounded = false;
    }

    void OnCollisionStay()
    {
        grounded = true;
    }
}