using System.Collections;
using System.Collections.Generic;
using UnityEngine;

public class TestEmitter : MonoBehaviour
{
    public GameObject objectPrefab;

    ONeillCylinder attractor;

    void Awake()
    {
        attractor = FindObjectOfType<ONeillCylinder>();
    }

    // Update is called once per frame
    void Update()
    {
        bool isFire = Input.GetButtonDown("Fire1");
        if (isFire)
        {
            var obj = Instantiate(objectPrefab, Vector3.zero, Quaternion.identity);
            obj.transform.parent = attractor.transform;
            var body = obj.GetComponent<Rigidbody>();
            var x = Random.Range(1, 5);
            var y = Random.Range(1, 5);
            if (Random.Range(0f, 1f) > 0.5) {
                x*=-1;
            }
            if (Random.Range(0f, 1f) > 0.5) {
                y*=-1;
            }
            body.AddRelativeForce(new Vector3(x, y, 0).normalized*0.2f, ForceMode.VelocityChange);
        }
    }
}
