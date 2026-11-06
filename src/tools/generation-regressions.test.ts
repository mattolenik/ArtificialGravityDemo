import { afterEach, describe, expect, it } from "vitest";
import * as fs from "node:fs/promises";
import * as os from "node:os";
import * as path from "node:path";
import { spawnSync } from "node:child_process";
import type { ServerState, ToolHandler } from "../index.js";
import { registerAudioTools } from "./audio-tools.js";
import { registerInputTools } from "./input-tools.js";
import { registerUIComponentTools } from "./ui-component-tools.js";
import { registerUIThemeTools } from "./ui-theme-tools.js";
import { registerScriptTools } from "./script-tools.js";
import { registerNavigationTools } from "./navigation-tools.js";

const directories: string[] = [];
afterEach(async () => {
  await Promise.all(directories.splice(0).map((dir) => fs.rm(dir, { recursive: true, force: true })));
});

async function fixture() {
  const root = await fs.mkdtemp(path.join(os.tmpdir(), "godot-generation-regression-"));
  directories.push(root);
  await fs.writeFile(path.join(root, "project.godot"), 'config_version=5\n[application]\nconfig/name="GenerationRegression"\n');
  const tools = new Map<string, ToolHandler>();
  const state: ServerState = { projectPath: root, editorConnected: false, editorPort: 6550 };
  for (const register of [registerAudioTools, registerInputTools, registerUIComponentTools,
    registerUIThemeTools, registerScriptTools, registerNavigationTools]) register(tools, state);
  return {
    root,
    async call(name: string, args: unknown): Promise<any> {
      const tool = tools.get(name)!;
      return tool.handler(tool.inputSchema.parse(args));
    },
    read: (file: string) => fs.readFile(path.join(root, file), "utf-8"),
    write: (file: string, data: string) => fs.writeFile(path.join(root, file), data),
  };
}

const audio = `[gd_resource type="AudioBusLayout" load_steps=3 format=3]
[ext_resource type="AudioEffect" path="res://external_effect.tres" id="External"]
[sub_resource type="AudioEffectReverb" id="Reverb"]
room_size = 0.8
[resource]
resource_name = "Keep this layout"
metadata/custom = {
"preserve": [1, 2]
}
bus/0/name = &"Master"
bus/0/effect/0/effect = SubResource("Reverb")
bus/0/effect/0/enabled = true
bus/1/name = &"RemoveMe"
bus/2/name = &"Music"
bus/2/volume_db = -2.0
bus/2/send = &"Master"
bus/2/effect/0/effect = ExtResource("External")
bus/2/effect/0/enabled = false
bus/2/metadata/custom = {"future": [1, 2]}
`;
const mouse = 'Object(InputEventMouseButton,"button_index":1,"ctrl_pressed":true,"shift_pressed":true,"resource_name":"preserve")';
const key = 'Object(InputEventKey,"physical_keycode":0,"key_label":65,"location":2,"device":-1)';
const input = `config_version=5
[application]
config/name="GenerationRegression"
[input]
modified_click={
"deadzone": 0.25,
"future_setting": {"nested": [1, 2]},
"events": [${mouse}, ${key}]
}
[rendering]
renderer/rendering_method="gl_compatibility"
`;

describe("registered generation tools regressions", () => {
  it("lists StringName audio buses as decoded names instead of parser Raw tags", async () => {
    const f = await fixture();
    const escapedBus = 'Music "live" \\ mix';
    await f.write("players.tscn", `[gd_scene format=3]
[node name="Main" type="Node"]
[node name="Music" type="AudioStreamPlayer" parent="."]
bus = &"Music"
[node name="Escaped" type="AudioStreamPlayer2D" parent="."]
bus = &${JSON.stringify(escapedBus)}
[node name="Dialog" type="AudioStreamPlayer3D" parent="."]
bus = "Dialog"
[node name="Default" type="AudioStreamPlayer" parent="."]
`);
    const result = await f.call("godot_audio_list_players", { scenePath: "players.tscn" });
    expect(result.playerCount).toBe(4);
    expect(result.players.map((player: { bus: string }) => player.bus))
      .toEqual(["Music", escapedBus, "Dialog", "Master"]);
  });

  it("preserves audio effects, resource sections and unknown properties during all bus edits", async () => {
    const f = await fixture();
    await f.write("default_bus_layout.tres", audio);
    await f.call("godot_audio_set_bus", { name: "Master", volumeDb: -6 });
    let content = await f.read("default_bus_layout.tres");
    expect(content).toContain('bus/0/effect/0/effect = SubResource("Reverb")');
    expect(content).toContain('bus/2/effect/0/effect = ExtResource("External")');
    await f.call("godot_audio_remove_bus", { name: "RemoveMe" });
    await f.call("godot_audio_apply_mix_profile", { profile: "paused", createMissingBuses: false });
    content = await f.read("default_bus_layout.tres");
    expect(content).toContain('[ext_resource type="AudioEffect"');
    expect(content).toContain('[sub_resource type="AudioEffectReverb"');
    expect(content).toContain('metadata/custom = {\n"preserve": [1, 2]\n}');
    expect(content).toContain('bus/1/effect/0/effect = ExtResource("External")');
    expect(content).toContain('bus/1/effect/0/enabled = false');
    expect(content).toContain('bus/1/metadata/custom = {"future": [1, 2]}');
    expect(content).not.toContain("RemoveMe");
    await f.write("invalid.tres", '[gd_resource type="Resource" format=3]\n[resource]\n');
    await expect(f.call("godot_audio_set_bus", { path: "invalid.tres", name: "Music" })).rejects.toThrow("Expected an AudioBusLayout");
    expect(await f.read("invalid.tres")).toContain('type="Resource"');
  });

  it("preserves compact audio assignments and quoted bus-like text", async () => {
    const f = await fixture();
    await f.write("default_bus_layout.tres", `[gd_resource type="AudioBusLayout" format=3]
[resource]
bus/0/name = &"Master" bus/0/metadata/custom = {"text": "bus/42/name = fake", "values": [1, 2]}
bus/1/name = &"RemoveMe" bus/1/send = &"Master"
bus/2/name = &"Music" bus/2/send = &"RemoveMe" bus/2/metadata/unknown = 42
`);
    await f.call("godot_audio_set_bus", { name: "Music", volumeDb: -3 });
    await f.call("godot_audio_remove_bus", { name: "RemoveMe" });
    const content = await f.read("default_bus_layout.tres");
    expect(content).toContain('bus/0/metadata/custom = {"text": "bus/42/name = fake", "values": [1, 2]}');
    expect(content).toContain('bus/1/name = &"Music"');
    expect(content).toContain('bus/1/send = &"Master"');
    expect(content).toContain('bus/1/metadata/unknown = 42');
  });

  it("preserves existing binding literals and unknown action fields on add/append/remove/preset", async () => {
    const f = await fixture();
    await f.write("project.godot", input);
    await f.call("godot_input_set_action", { action: "jump", events: [{ type: "key", physicalKeycode: 32 }] });
    await f.call("godot_input_set_action", { action: "modified_click", deadzone: 0.4, replaceEvents: false, events: [{ type: "joy_button", buttonIndex: 0 }] });
    await f.call("godot_input_remove_action", { action: "jump" });
    await f.call("godot_input_apply_preset", { preset: "2d_platformer" });
    const content = await f.read("project.godot");
    expect(content).toContain(mouse);
    expect(content).toContain(key);
    expect(content).toContain('"future_setting": {"nested": [1, 2]}');
    expect(content).toContain('[rendering]\nrenderer/rendering_method="gl_compatibility"');
    // Explicit replacement must still replace a modified binding with a plain click.
    await f.call("godot_input_set_action", { action: "modified_click", events: [{ type: "mouse_button", buttonIndex: 1 }] });
    expect(await f.read("project.godot")).not.toContain(mouse);
  });

  it("appends typed event arrays without confusing nested action fields", async () => {
    const f = await fixture();
    await f.write("project.godot", `config_version=5
[input]
"custom binding"={
"future": {"deadzone": 0.9, "events": [99]},
"deadzone": 0.2,
"events": Array[InputEvent]([${mouse}])
}
`);
    await f.call("godot_input_set_action", { action: "custom binding", replaceEvents: false, events: [{ type: "joy_button", buttonIndex: 2 }] });
    const content = await f.read("project.godot");
    expect(content).toContain(mouse);
    expect(content).toContain('"deadzone": 0.2');
    expect(content).toContain('"future": {"deadzone": 0.9, "events": [99]}');
    expect((await f.call("godot_input_get_action", { action: "custom binding" })).action.events).toHaveLength(2);
  });

  it("canonicalizes nested UI script references and accepts empty menu/dialog buttons", async () => {
    const f = await fixture();
    for (const [kind, args] of [
      ["menu", { title: "Menu", buttons: [] }],
      ["dialog", { title: "Dialog", buttons: [] }],
      ["hud", { elements: ["health"] }],
    ] as const) {
      await f.call(`godot_ui_create_${kind}`, { path: `scenes/${kind}.tscn`, ...args });
      expect(await f.read(`scenes/${kind}.tscn`)).toContain(`path="res://scenes/${kind}.gd"`);
      if (kind !== "hud") expect(await f.read(`scenes/${kind}.gd`)).toContain("func _ready() -> void:\n\tpass");
    }
  });

  it("keeps zero alpha and explicit zero content margins", async () => {
    const f = await fixture();
    await f.call("godot_ui_create_stylebox", { path: "transparent.tres", bg_color: { r: 0, g: 0, b: 0, a: 0 }, content_margins: 0 });
    expect(await f.read("transparent.tres")).toContain("bg_color = Color(0, 0, 0, 0)");
    expect(await f.read("transparent.tres")).toContain("content_margin_left = 0");
    await f.call("godot_ui_create_theme", { path: "theme.tres", colors: { text: { r: 1, g: 1, b: 1, a: 0 } }, styleboxes: { panel: { bg_color: { r: 0, g: 0, b: 0, a: 0 }, content_margin_left: 0 } } });
    expect(await f.read("theme.tres")).toContain("font_color = Color(1, 1, 1, 0)");
    expect(await f.read("theme.tres")).toContain("content_margin_left = 0");
  });

  it("rejects nonspatial movement templates and generates dimension-compatible movement", async () => {
    const f = await fixture();
    await expect(f.call("godot_generate_script", { description: "player movement", extends: "Node" })).rejects.toThrow("Movement requires");
    const inferred = await f.call("godot_generate_script", { description: "player movement" });
    expect(inferred.generatedScript).toContain("extends Node2D");
    await expect(f.call("godot_generate_script", { description: "player movement", extends: "NavigationAgent2D" })).rejects.toThrow("Movement requires");
    const result = await f.call("godot_generate_script", { description: "player movement", extends: "Node3D" });
    expect(result.generatedScript).toContain("Vector3(direction.x, 0.0, direction.y)");
  });

  it("rejects cross-dimensional/disabled coverage and null navigation resources", async () => {
    const f = await fixture();
    await f.write("nav.tscn", '[gd_scene format=3]\n[node name="Root" type="Node"]\n[node name="Region" type="NavigationRegion3D" parent="."]\nenabled = false\nnavigation_mesh = null\n[node name="Agent" type="NavigationAgent2D" parent="."]\n');
    expect((await f.call("godot_navigation_validate_paths", { scenePath: "nav.tscn" })).valid).toBe(false);
    await expect(f.call("godot_navigation_validate_paths", { scenePath: "nav.tscn", strict: true })).rejects.toThrow("Navigation validation failed");
    expect((await f.call("godot_navigation_build_bake_plan", { scenePath: "nav.tscn" })).readyForBake).toBe(false);
  });
});

const godot = process.env.GODOT_BIN || "godot";
const hasGodot = spawnSync(godot, ["--version"], { encoding: "utf8", timeout: 10000 }).status === 0;
it.skipIf(!hasGodot)("loads generated output and preserved audio/input state in Godot", async () => {
  const f = await fixture();
  await f.write("project.godot", input);
  await f.write("default_bus_layout.tres", audio);
  await f.write("external_effect.tres", '[gd_resource type="AudioEffectAmplify" format=3]\n[resource]\nvolume_db = -3.0\n');
  await f.call("godot_audio_set_bus", { name: "Master", volumeDb: -6 });
  await f.call("godot_audio_remove_bus", { name: "RemoveMe" });
  await f.call("godot_input_set_action", { action: "jump", events: [{ type: "key", physicalKeycode: 32 }] });
  await f.call("godot_ui_create_menu", { path: "scenes/menu.tscn", title: "Menu", buttons: [] });
  await f.call("godot_ui_create_dialog", { path: "scenes/dialog.tscn", title: "Dialog", buttons: [] });
  await f.call("godot_ui_create_hud", { path: "scenes/hud.tscn", elements: ["health"] });
  await f.call("godot_ui_create_stylebox", { path: "transparent.tres", bg_color: { r: 0, g: 0, b: 0, a: 0 }, content_margins: 0 });
  const inferred = await f.call("godot_generate_script", { description: "player movement" });
  await f.write("inferred.gd", inferred.generatedScript);
  const scripts: string[] = ["res://inferred.gd"];
  for (const base of ["Node2D", "Node3D", "Control", "CharacterBody2D", "CharacterBody3D"]) {
    const { generatedScript } = await f.call("godot_generate_script", { description: "player movement and jump", extends: base });
    await f.write(`${base}.gd`, generatedScript);
    scripts.push(`res://${base}.gd`);
  }
  await f.write("verify.gd", `extends SceneTree
func _initialize():
\tAudioServer.set_bus_layout(load("res://default_bus_layout.tres"))
\tassert(AudioServer.get_bus_effect_count(0) == 1)
\tassert(AudioServer.get_bus_effect_count(1) == 1)
\tassert(not AudioServer.is_bus_effect_enabled(1, 0))
\tInputMap.load_from_project_settings()
\tassert(InputMap.action_get_events("modified_click")[0].ctrl_pressed)
\tassert(InputMap.action_get_events("modified_click")[1].key_label == 65)
\tvar style = load("res://transparent.tres")
\tassert(style.bg_color.a == 0.0)
\tassert(style.content_margin_left == 0.0)
\tfor script_path in ${JSON.stringify(scripts)}:
\t\tassert(load(script_path).can_instantiate())
\tfor kind in ["menu", "dialog", "hud"]:
\t\tvar scene = load("res://scenes/%s.tscn" % kind).instantiate()
\t\tassert(scene.get_script().can_instantiate())
\t\troot.add_child(scene)
\t\tscene.free()
\tprint("GENERATION_REGRESSIONS_OK")
\tquit()
`);
  const result = spawnSync(godot, ["--headless", "--path", f.root, "--script", "res://verify.gd"], { encoding: "utf8", timeout: 20000 });
  expect(result.error).toBeUndefined();
  expect(result.status, result.stderr).toBe(0);
  expect(result.stderr).not.toMatch(/(?:SCRIPT |SHADER )?ERROR:/);
  expect(result.stdout).toContain("GENERATION_REGRESSIONS_OK");
}, 30000);
