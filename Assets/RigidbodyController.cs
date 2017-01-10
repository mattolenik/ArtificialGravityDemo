using System;
using System.Collections.Generic;
using System.Linq;
using UnityEngine;
using UnityStandardAssets.CrossPlatformInput;

[RequireComponent(typeof(Rigidbody))]
[RequireComponent(typeof(CapsuleCollider))]
[RequireComponent(typeof(CapturedBody))]
public class RigidbodyController : MonoBehaviour
{
    public float Speed = 10.0f;

    public bool Oomph = true;

    public bool CanJump = true;
    
    public float JumpForce = 2.0f;

    public float JumpDelay = 1.0f;

    bool grounded;

    CapturedBody body;

    TimeSpan jumpDelay;
    DateTime lastJump = DateTime.MinValue;
    float angle;
    float right;
    float forward;
    bool jumping;

    void Start()
    {
        body = gameObject.GetComponent<CapturedBody>();
        body.FreezeRotation = true;
        jumpDelay = TimeSpan.FromSeconds(JumpDelay);
    }

    void Update()
    {
        right = Input.GetAxis("Horizontal");
        forward = Input.GetAxis("Vertical");
        jumping = Input.GetButton("Jump") && DateTime.Now - lastJump > jumpDelay;
    }

    void FixedUpdate()
    {
        if (grounded)
        {
            var s = Speed / body.Velocity.magnitude;
            var moveForce = transform.forward * (forward * s) + transform.right * (right * s);
            moveForce = Vector3.ClampMagnitude(moveForce, s);
            if (jumping)
            {
                moveForce += body.Up * JumpForce;
                lastJump = DateTime.Now;
            }
            body.AddForce(moveForce);

            if (Oomph)
            {
                var oomphForce = 1f / body.Velocity.magnitude;
                //oomphForce = Mathf.Clamp(oomphForce, 0, Speed);
                body.AddForce(moveForce.normalized * oomphForce);
            }
        }
        grounded = false;
        Debug.Log(body.Body.velocity.magnitude);
    }

    void OnCollisionStay()
    {
        grounded = true;
    }
}