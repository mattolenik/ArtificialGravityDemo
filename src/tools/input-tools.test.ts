import { describe, it, expect } from "vitest";
import {
  registerInputTools,
  parseInputMapContent,
  updateInputSection,
  type InputAction,
} from "./input-tools.js";
import type { ToolHandler, ServerState } from "../index.js";

describe("Input Tools", () => {
  it("parses input actions and common event types", () => {
    const content = `config_version=5

[input]

move_left={
"deadzone": 0.5,
"events": [Object(InputEventKey,"resource_local_to_scene":false,"resource_name":"","device":-1,"window_id":0,"alt_pressed":false,"shift_pressed":false,"ctrl_pressed":false,"meta_pressed":false,"pressed":false,"keycode":0,"physical_keycode":65,"key_label":0,"unicode":97,"location":0,"echo":false,"script":null), Object(InputEventMouseButton,"resource_local_to_scene":false,"resource_name":"","device":-1,"window_id":0,"alt_pressed":false,"shift_pressed":false,"ctrl_pressed":false,"meta_pressed":false,"button_mask":0,"position":Vector2(0, 0),"global_position":Vector2(0, 0),"factor":1.0,"button_index":1,"pressed":false,"canceled":false,"double_click":false,"script":null)]
}

[application]
config/name="TestGame"
`;

    const parsed = parseInputMapContent(content);

    expect(parsed.hasInputSection).toBe(true);
    expect(parsed.actions.length).toBe(1);
    expect(parsed.actions[0].name).toBe("move_left");
    expect(parsed.actions[0].deadzone).toBe(0.5);
    expect(parsed.actions[0].events.length).toBe(2);
    expect(parsed.actions[0].events[0].type).toBe("key");
    expect(parsed.actions[0].events[1].type).toBe("mouse_button");
  });

  it("writes a new input section when missing", () => {
    const content = `config_version=5

[application]
config/name="NoInputYet"
`;

    const actions: InputAction[] = [
      {
        name: "jump",
        deadzone: 0.5,
        events: [
          {
            type: "key",
            keycode: 32,
            physicalKeycode: 32,
            unicode: 32,
            device: -1,
            alt: false,
            shift: false,
            ctrl: false,
            meta: false,
          },
        ],
      },
    ];

    const updated = updateInputSection(content, actions);
    const parsed = parseInputMapContent(updated);

    expect(updated).toContain("[input]");
    expect(updated).toContain("jump={");
    expect(parsed.hasInputSection).toBe(true);
    expect(parsed.actions[0].name).toBe("jump");
  });

  it("round-trips joypad event data", () => {
    const content = `config_version=5

[input]

`;

    const actions: InputAction[] = [
      {
        name: "move_axis",
        deadzone: 0.3,
        events: [
          {
            type: "joy_axis",
            axis: 0,
            axisValue: -1,
            device: 0,
          },
          {
            type: "joy_button",
            buttonIndex: 1,
            device: 0,
          },
        ],
      },
    ];

    const next = updateInputSection(content, actions);
    const parsed = parseInputMapContent(next);

    expect(parsed.actions.length).toBe(1);
    expect(parsed.actions[0].events[0].type).toBe("joy_axis");
    expect(parsed.actions[0].events[1].type).toBe("joy_button");
  });

  it("registers all input tools", () => {
    const tools = new Map<string, ToolHandler>();
    const state: ServerState = {
      projectPath: process.cwd(),
      editorConnected: false,
      editorPort: 6550,
    };

    registerInputTools(tools, state);

    expect(tools.has("godot_input_list_actions")).toBe(true);
    expect(tools.has("godot_input_get_action")).toBe(true);
    expect(tools.has("godot_input_set_action")).toBe(true);
    expect(tools.has("godot_input_remove_action")).toBe(true);
    expect(tools.has("godot_input_list_presets")).toBe(true);
    expect(tools.has("godot_input_apply_preset")).toBe(true);
  });
});
