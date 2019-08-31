using System;
using System.Collections.Generic;
using System.Linq;
using UnityEngine;
using UnityStandardAssets.CrossPlatformInput;

[RequireComponent(typeof(Rigidbody))]
[RequireComponent(typeof(CapsuleCollider))]
[RequireComponent(typeof(CapturedBody))]
public class CapturedRigidbodyController : MonoBehaviour
{
    public float Speed = 10.0f;

    public bool CanJump = true;
    
    public float JumpForce = 2.0f;

    public float JumpDelay = 1.0f;

    [Tooltip("How fast the character can move under their own power")]
    public float RunSpeed = 15f;

    bool grounded;
    float lastJump = -1f;
    CapturedBody body;

    void Start()
    {
        body = gameObject.GetComponent<CapturedBody>();
        //body.FreezeRotation = true;
    }

    void Update()
    {
        //transform.up = -body.Gravity;
        Debug.DrawLine(transform.position, transform.position - body.Gravity*3);
    }

    public void Move(float forward, float right, bool jumping)
    {
        if (grounded)
        {
            // Apply less force as speed approaches running speed.
            // This causes a quicker start with force that levels off as speed
            // approaches the desired top speed.
            var x = Speed * -Mathf.Log(Mathf.Abs(body.Velocity.x) / RunSpeed + 0.01f);
            var z = Speed * -Mathf.Log(Mathf.Abs(body.Velocity.z) / RunSpeed + 0.01f);
            var moveForce = transform.forward * (forward * z) + transform.right * (right * x);
            if (jumping && Time.time - lastJump > JumpDelay)
            {
                moveForce += -body.Gravity * JumpForce;
                lastJump = Time.time;
            }
            body.AddForce(moveForce);
            //Debug.Log("f: " + moveForce.magnitude.ToString("n2") + " | v: " + body.Velocity.magnitude.ToString("n2") + " | z: " + z.ToString("n2"));
        }
        grounded = false;
    }

    void OnCollisionStay()
    {
        grounded = true;
    }
}