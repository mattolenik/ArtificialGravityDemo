using UnityEngine;

public class MeanVector3
{
    readonly Vector3[] samples;
    Vector3 lastMean;
    int numSamples;
    bool newSamples;

    public MeanVector3(int samples)
    {
        this.samples = new Vector3[samples];
    }

    public void Sample(Vector3 value)
    {
        Vector3 lastSample = samples[0];
        for (int i = 1; i < samples.Length; i++)
        {
            var tmp = samples[i];
            samples[i] = lastSample;
            lastSample = tmp;
        }
        samples[0] = value;
        if (numSamples < samples.Length)
        {
            numSamples++;
        }
        newSamples = true;
    }

    public static implicit operator Vector3(MeanVector3 mean)
    {
        return mean.Mean;
    }

    public Vector3 Mean
    {
        get
        {
            if (!newSamples)
            {
                return lastMean;
            }
            float x = 0, y = 0, z = 0;
            // Only include values that have actually been measured so far.
            // Prevents averaging in the initial zeroed values.
            for (int i = 0; i < numSamples; i++)
            {
                x += samples[i].x;
                y += samples[i].y;
                z += samples[i].z;
            }
            lastMean = new Vector3(x / numSamples, y / numSamples, z / numSamples);
            newSamples = false;
            return lastMean;
        }
    }
}