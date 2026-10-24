using UnityEditor;
using UnityEditor.UIElements;
using UnityEngine;
using UnityEngine.UIElements;

[CustomEditor(typeof(TestEmitter))]
public class TestEmitterEditor : Editor
{
    public override VisualElement CreateInspectorGUI()
    {
        var emitter = (TestEmitter)target;
        var root = new VisualElement();
        InspectorElement.FillDefaultInspector(root, serializedObject, this);

        var spawn = new Button(emitter.Spawn) { text = "Spawn" };
        var clear = new Button(emitter.ClearSpawned) { text = "Clear spawned" };
        spawn.style.flexGrow = 1;
        clear.style.flexGrow = 1;
        var buttons = new VisualElement();
        buttons.style.flexDirection = FlexDirection.Row;
        buttons.style.marginTop = 8;
        buttons.Add(spawn);
        buttons.Add(clear);
        root.Add(buttons);

        var frame = new Button(() => FrameSpawnPoint(emitter)) { text = "Center Scene view on spawn point" };
        root.Add(frame);

        var info = new HelpBox("", HelpBoxMessageType.Info);
        root.Add(info);

        // Refresh the readout and button state while the Inspector is open.
        root.schedule.Execute(() =>
        {
            if (!emitter)
            {
                return;
            }
            var playing = EditorApplication.isPlaying;
            spawn.SetEnabled(playing);
            clear.SetEnabled(playing);
            var station = emitter.Station;
            if (!station)
            {
                info.text = "No ONeillCylinder in the scene.";
                return;
            }
            var radius = station.GetComponent<MeshFilter>().sharedMesh.bounds.max.x;
            var gravity = station.Acceleration * emitter.DistanceFromAxis / radius;
            var outside = emitter.DistanceFromAxis + emitter.BoxSize / 2f > radius ? "\nThe spawn point is outside the floor." : "";
            var status = playing ? $"{emitter.SpawnedCount} boxes spawned." : "Enter Play mode to spawn boxes.";
            info.text = $"Floor is {radius:F0} m from the axis. Apparent gravity at the spawn point: {gravity:F2} m/s².{outside}\n{status}";
        }).Every(250);

        return root;
    }

    // Look along the station's axis with "up" toward the axis, so boxes fall down the screen
    // and any Coriolis drift shows up as sideways motion.
    static void FrameSpawnPoint(TestEmitter emitter)
    {
        if (!emitter.Station)
        {
            return;
        }
        var view = SceneView.lastActiveSceneView ? SceneView.lastActiveSceneView : EditorWindow.GetWindow<SceneView>();
        var size = Mathf.Max(emitter.BoxSize * 10f, emitter.Count > 1 ? emitter.Spread * 3f : 0f);
        view.LookAt(emitter.SpawnPoint, Quaternion.LookRotation(emitter.Station.transform.forward, emitter.SpawnUp), size);
        view.Focus();
    }
}
