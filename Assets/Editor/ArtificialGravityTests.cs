using NUnit.Framework;
using UnityEngine;

public class ArtificialGravityTests
{
    /// <summary>
    /// Drop from 10 m at rest relative to the floor of a 500 m, 1 g station. Seen from outside,
    /// the object just keeps its tangential speed and moves in a straight line, which gives an
    /// exact landing time and point to check the rotating-frame forces against.
    /// </summary>
    [Test]
    public void DropLandsAntispinward()
    {
        const double R = 500, h = 10, g = 9.8;
        const float dt = 0.02f;
        var w = System.Math.Sqrt(g / R);

        // Exact answer from the inertial frame.
        var a = R - h;
        var chord = System.Math.Sqrt(R * R - a * a);
        var expectedTime = chord / (w * a);
        var expectedLag = (w * expectedTime - System.Math.Atan(chord / a)) * R;

        // Same drop integrated in the rotating frame, the way Unity steps it.
        // Spin is about +Z, so spinward at the bottom of the cylinder is +X.
        var omega = Vector3.forward * (float)w;
        var p = new Vector3(0, -(float)a, 0);
        var v = Vector3.zero;
        var t = 0f;
        while (p.magnitude < R)
        {
            v += ONeillCylinder.FictitiousAcceleration(p, v, omega) * dt;
            p += v * dt;
            t += dt;
        }
        var lag = -Mathf.Atan2(p.x, -p.y) * (float)R;

        Debug.Log($"fall {t:F3}s (exact {expectedTime:F3}s), lands {lag:F3}m antispinward (exact {expectedLag:F3}m)");
        Assert.That(t, Is.EqualTo(expectedTime).Within(2 * dt));
        Assert.That(lag, Is.EqualTo(expectedLag).Within(0.05 * expectedLag));
    }
}
