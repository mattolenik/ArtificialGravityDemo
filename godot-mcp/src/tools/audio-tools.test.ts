import { describe, it, expect } from "vitest";
import {
  registerAudioTools,
  parseAudioBusLayoutContent,
  serializeAudioBusLayoutContent,
  setDefaultBusLayoutInProject,
  getDefaultBusLayoutFromProject,
  buildEffectChainScript,
  applyMixProfileToBuses,
  type AudioBus,
} from "./audio-tools.js";
import type { ToolHandler, ServerState } from "../index.js";

describe("Audio Tools", () => {
  it("round-trips audio bus layout content", () => {
    const buses: AudioBus[] = [
      {
        name: "Music",
        send: "Master",
        volumeDb: -3.5,
        mute: false,
        solo: false,
        bypassFx: false,
      },
      {
        name: "SFX",
        send: "Master",
        volumeDb: -1,
        mute: false,
        solo: false,
        bypassFx: true,
      },
    ];

    const serialized = serializeAudioBusLayoutContent(buses);
    const parsed = parseAudioBusLayoutContent(serialized);

    expect(parsed).toEqual(buses);
  });

  it("supports explicit Master bus layouts", () => {
    const buses: AudioBus[] = [
      {
        name: "Master",
        send: "",
        volumeDb: 0,
        mute: false,
        solo: false,
        bypassFx: false,
      },
      {
        name: "Music",
        send: "Master",
        volumeDb: -3,
        mute: false,
        solo: false,
        bypassFx: false,
      },
    ];

    const serialized = serializeAudioBusLayoutContent(buses);
    const parsed = parseAudioBusLayoutContent(serialized);

    expect(serialized).toContain('bus/0/name = &"Master"');
    expect(parsed[0].name).toBe("Master");
    expect(parsed[1].name).toBe("Music");
  });

  it("parses compact bus layout lines", () => {
    const content = `[gd_resource type="AudioBusLayout" format=3]
[resource]
bus/1/name = &"Music" bus/1/solo = false bus/1/mute = false bus/1/bypass_fx = false bus/1/volume_db = -4 bus/1/send = &"Master"
bus/2/name = &"SFX"
bus/2/solo = false
bus/2/mute = true
bus/2/bypass_fx = true
bus/2/volume_db = 1.5
bus/2/send = &"Master"
`;

    const parsed = parseAudioBusLayoutContent(content);

    expect(parsed.length).toBe(2);
    expect(parsed[0].name).toBe("Music");
    expect(parsed[1].mute).toBe(true);
    expect(parsed[1].volumeDb).toBe(1.5);
  });

  it("sets and reads project default bus layout path", () => {
    const project = `config_version=5

[application]
config/name="AudioGame"
`;

    const updated = setDefaultBusLayoutInProject(
      project,
      "res://audio/default_bus_layout.tres"
    );
    const parsed = getDefaultBusLayoutFromProject(updated);

    expect(updated).toContain("[audio]");
    expect(updated).toContain(
      'buses/default_bus_layout="res://audio/default_bus_layout.tres"'
    );
    expect(parsed).toBe("res://audio/default_bus_layout.tres");
  });

  it("builds effect chain scripts from presets", () => {
    const script = buildEffectChainScript("sfx_punch", "SFX", true);

    expect(script).toContain("AudioServer.get_bus_index");
    expect(script).toContain("AudioEffectCompressor");
    expect(script).toContain('bus_name := "SFX"');
  });

  it("applies mix profile overrides", () => {
    const buses: AudioBus[] = [
      {
        name: "Music",
        send: "Master",
        volumeDb: 0,
        mute: false,
        solo: false,
        bypassFx: false,
      },
    ];

    const result = applyMixProfileToBuses(
      buses,
      [{ name: "Music", volumeDb: -8 }, { name: "SFX", volumeDb: -2 }],
      true
    );

    expect(result.applied).toContain("Music");
    expect(result.created).toContain("SFX");
    expect(result.buses.find((bus) => bus.name === "Music")?.volumeDb).toBe(-8);
    expect(result.buses.find((bus) => bus.name === "SFX")?.volumeDb).toBe(-2);
  });

  it("registers all audio tools", () => {
    const tools = new Map<string, ToolHandler>();
    const state: ServerState = {
      projectPath: process.cwd(),
      editorConnected: false,
      editorPort: 6550,
    };

    registerAudioTools(tools, state);

    expect(tools.has("godot_audio_create_bus_layout")).toBe(true);
    expect(tools.has("godot_audio_read_bus_layout")).toBe(true);
    expect(tools.has("godot_audio_set_bus")).toBe(true);
    expect(tools.has("godot_audio_remove_bus")).toBe(true);
    expect(tools.has("godot_audio_list_players")).toBe(true);
    expect(tools.has("godot_audio_configure_player")).toBe(true);
    expect(tools.has("godot_audio_list_effect_presets")).toBe(true);
    expect(tools.has("godot_audio_generate_effect_chain_script")).toBe(true);
    expect(tools.has("godot_audio_apply_mix_profile")).toBe(true);
  });
});
