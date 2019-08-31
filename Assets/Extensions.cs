using System;
using UnityEngine;

public static class Extensions
{
    public static void MoveRotationTorque(this Rigidbody body, Quaternion targetRotation)
    {
        body.maxAngularVelocity = 1000;

        Quaternion r = targetRotation * Quaternion.Inverse(body.rotation);
        body.AddTorque(r.x / Time.fixedDeltaTime, r.y / Time.fixedDeltaTime, r.z / Time.fixedDeltaTime, ForceMode.VelocityChange);
        body.angularVelocity = Vector3.zero;
    }

    public static T FindComponentUpwards<T>(this Component obj)
    {
        T component;
        if (TryFindComponentUpwards(obj, out component))
        {
            return component;
        }
        throw new MissingComponentException($"Could not find component of type {typeof(T).Name} anywhere upwards in the heirarchy");
    }

    public static bool TryFindComponentUpwards<T>(this Component obj, out T component)
    {
        var p = obj.transform.parent;
        while (p != null)
        {
            if (p.TryGetComponent(out component))
            {
                return true;
            }
            p = p.parent;
        }
        component = default(T);
        return false;
    }
}