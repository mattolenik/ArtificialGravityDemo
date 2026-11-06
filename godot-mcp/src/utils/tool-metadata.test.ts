import { describe, expect, it } from "vitest";
import {
  isMutatingToolName,
  requiresEditorBridgeConnection,
  usesEditorBridgeTool,
} from "./tool-metadata.js";

describe("tool metadata utils", () => {
  it("classifies mutating tool names consistently", () => {
    expect(isMutatingToolName("godot_input_set_action")).toBe(true);
    expect(isMutatingToolName("godot_input_apply_preset")).toBe(true);
    expect(isMutatingToolName("godot_navigation_configure_region")).toBe(true);
    expect(isMutatingToolName("godot_audio_configure_player")).toBe(true);
    expect(isMutatingToolName("godot_animation_setup_scene")).toBe(true);
    expect(isMutatingToolName("godot_animation_build_state_machine_plan")).toBe(true);
    expect(isMutatingToolName("godot_animation_build_blend_space_plan")).toBe(true);
    expect(isMutatingToolName("godot_runtime_tap_action")).toBe(true);
    expect(isMutatingToolName("godot_runtime_capture_screenshot")).toBe(true);
    expect(isMutatingToolName("godot_runtime_status")).toBe(false);
    expect(isMutatingToolName("godot_read_scene")).toBe(false);
    expect(isMutatingToolName("godot_list_resources")).toBe(false);
  });

  it("identifies editor bridge tools", () => {
    expect(usesEditorBridgeTool("godot_connect")).toBe(true);
    expect(usesEditorBridgeTool("godot_editor_add_node")).toBe(true);
    expect(usesEditorBridgeTool("godot_runtime_click")).toBe(true);
    expect(usesEditorBridgeTool("godot_connection_status")).toBe(true);
    expect(usesEditorBridgeTool("godot_read_scene")).toBe(false);
  });

  it("marks only editor operations as requiring active connection", () => {
    expect(requiresEditorBridgeConnection("godot_editor_add_node")).toBe(true);
    expect(requiresEditorBridgeConnection("godot_runtime_wait")).toBe(true);
    expect(requiresEditorBridgeConnection("godot_editor_connection_status")).toBe(false);
    expect(requiresEditorBridgeConnection("godot_connect")).toBe(false);
  });
});
