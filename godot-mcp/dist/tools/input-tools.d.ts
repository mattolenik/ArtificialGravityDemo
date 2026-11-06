/**
 * Input map tools for Godot MCP
 *
 * Provides helpers for reading and editing the [input] section in project.godot.
 */
import type { ToolHandler, ServerState } from "../index.js";
export type InputEvent = {
    type: "key";
    keycode: number;
    physicalKeycode: number;
    unicode: number;
    device: number;
    alt: boolean;
    shift: boolean;
    ctrl: boolean;
    meta: boolean;
} | {
    type: "mouse_button";
    buttonIndex: number;
    device: number;
    doubleClick: boolean;
} | {
    type: "joy_button";
    buttonIndex: number;
    device: number;
} | {
    type: "joy_axis";
    axis: number;
    axisValue: number;
    device: number;
} | {
    type: "raw";
    raw: string;
};
export interface InputAction {
    name: string;
    deadzone: number;
    events: InputEvent[];
}
export declare function registerInputTools(tools: Map<string, ToolHandler>, state: ServerState): void;
export declare function parseInputMapContent(content: string): {
    hasInputSection: boolean;
    actions: InputAction[];
};
export declare function updateInputSection(content: string, actions: InputAction[]): string;
//# sourceMappingURL=input-tools.d.ts.map