using UnityEngine;

public class RamaController : MonoBehaviour
{

    public float Speed;

    void Start()
    {
    }

    void FixedUpdate()
    {
        transform.Rotate(new Vector3(0f, 0f, Speed), Space.Self);
    }
}