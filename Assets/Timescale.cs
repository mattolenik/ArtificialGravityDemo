using UnityEngine;

public class Timescale : MonoBehaviour
{
    public float Scale = 1.0f;

    // Update is called once per frame
    void Update()
    {
        Time.timeScale = Scale;
        Time.fixedDeltaTime = 0.02F*Time.timeScale;
    }
}
