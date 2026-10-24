﻿using System.Collections.Generic;
using UnityEngine;

/// <summary>
/// Spawns test boxes inside the cylinder to see how falling objects behave.
/// Spawn them with the buttons in this component's Inspector while in Play mode.
/// </summary>
public class TestEmitter : MonoBehaviour
{
    public enum LaunchDirection { Random, Spinward, Antispinward, TowardAxis, TowardFloor }

    public GameObject objectPrefab;

    [Header("Spawn point")]
    [Tooltip("Distance from the spin axis in m: 0 is on the axis, the cylinder's radius is the floor. Position along the axis comes from this object.")]
    [Min(0f)] public float DistanceFromAxis = 0f;

    [Tooltip("Angle around the axis in degrees: 0 is straight below the axis (local −Y), positive is spinward.")]
    public float AngleAroundAxis = 0f;

    [Tooltip("Boxes per spawn.")]
    [Min(1)] public int Count = 1;

    [Tooltip("When spawning several boxes, each is offset randomly within this radius (m) so they don't spawn inside each other.")]
    [Min(0f)] public float Spread = 10f;

    [Header("Box")]
    [Tooltip("Edge length in m.")]
    [Min(0.01f)] public float BoxSize = 5f;

    [Tooltip("kg/m³; mass = density × size³. Water is 1000, wood about 600, 8 is a very light foam.")]
    [Min(0.001f)] public float Density = 8f;

    [Tooltip("Air drag coefficient; drag area = this × size². About 1.05 for a cube face-on, 0 disables air drag.")]
    [Min(0f)] public float DragCoefficient = 1.05f;

    [Header("Trail")]
    [Tooltip("Width in m.")]
    [Min(0f)] public float TrailWidth = 1.16f;

    [Tooltip("How long the trail lasts, in s.")]
    [Min(0f)] public float TrailTime = 100f;

    [Header("Launch (relative to the station)")]
    public LaunchDirection Direction = LaunchDirection.Random;

    [Tooltip("Each box gets a random speed in m/s between these. Set both to 0 to drop at rest.")]
    [Min(0f)] public float MinSpeed = 0.2f;
    [Min(0f)] public float MaxSpeed = 0.8f;

    ONeillCylinder station;

    readonly List<GameObject> spawned = new List<GameObject>();

    public ONeillCylinder Station => station ? station : station = FindAnyObjectByType<ONeillCylinder>();

    public int SpawnedCount
    {
        get
        {
            spawned.RemoveAll(o => o == null);
            return spawned.Count;
        }
    }

    public Vector3 SpawnPoint => Station.transform.TransformPoint(LocalSpawnPoint());

    /// <summary>Toward the axis at the spawn point, i.e. "up" for anything standing below it.</summary>
    public Vector3 SpawnUp => Station.transform.TransformDirection(-LocalOutward);

    public void Spawn()
    {
        var s = Station.transform;
        for (var i = 0; i < Count; i++)
        {
            var offset = Count > 1 ? Random.insideUnitSphere * Spread : Vector3.zero;
            var obj = Instantiate(objectPrefab, s.TransformPoint(LocalSpawnPoint() + offset), s.rotation, s);
            obj.transform.localScale = Vector3.one * BoxSize;
            obj.GetComponent<CapturedBody>().DragArea = DragCoefficient * BoxSize * BoxSize;
            var trail = obj.GetComponent<TrailRenderer>();
            trail.widthMultiplier = 1f;
            trail.startWidth = trail.endWidth = TrailWidth;
            trail.time = TrailTime;
            var body = obj.GetComponent<Rigidbody>();
            body.mass = Density * BoxSize * BoxSize * BoxSize;
            body.linearVelocity = s.TransformDirection(LocalLaunchDirection()) * Random.Range(MinSpeed, MaxSpeed);
            spawned.Add(obj);
        }
    }

    public void ClearSpawned()
    {
        foreach (var obj in spawned)
        {
            if (obj)
            {
                Destroy(obj);
            }
        }
        spawned.Clear();
    }

    // The station spins about its local Z, as ONeillCylinder assumes; angle 0 points along −Y.
    Vector3 LocalOutward
    {
        get
        {
            var a = AngleAroundAxis * Mathf.Deg2Rad;
            return new Vector3(Mathf.Sin(a), -Mathf.Cos(a), 0f);
        }
    }

    Vector3 LocalSpawnPoint()
    {
        var along = Station.transform.InverseTransformPoint(transform.position).z;
        return LocalOutward * DistanceFromAxis + Vector3.forward * along;
    }

    Vector3 LocalLaunchDirection()
    {
        var outward = LocalOutward;
        var spinward = Vector3.Cross(Vector3.forward, outward) * Mathf.Sign(Station.Axis.z);
        switch (Direction)
        {
            case LaunchDirection.Spinward: return spinward;
            case LaunchDirection.Antispinward: return -spinward;
            case LaunchDirection.TowardAxis: return -outward;
            case LaunchDirection.TowardFloor: return outward;
            default: return Random.insideUnitCircle.normalized;
        }
    }

    void OnDrawGizmosSelected()
    {
        if (!Station)
        {
            return;
        }
        var s = Station.transform;
        Gizmos.color = Color.yellow;
        Gizmos.matrix = Matrix4x4.TRS(s.TransformPoint(LocalSpawnPoint()), s.rotation, Vector3.one);
        Gizmos.DrawWireCube(Vector3.zero, Vector3.one * BoxSize);
        if (Count > 1)
        {
            Gizmos.DrawWireSphere(Vector3.zero, Spread);
        }
        if (Direction != LaunchDirection.Random)
        {
            Gizmos.DrawRay(Vector3.zero, LocalLaunchDirection() * BoxSize * 3f);
        }
    }
}
