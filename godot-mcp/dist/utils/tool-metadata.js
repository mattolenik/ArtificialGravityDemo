const MUTATING_TOOL_KEYWORDS = [
    "_write_",
    "_add_",
    "_remove_",
    "_modify_",
    "_set_",
    "_apply_",
    "_create_",
    "_generate_",
    "_init_",
    "_update_",
    "_configure_",
    "_setup_",
    "_run_",
    "_stop_",
    "_open_",
    "_save_",
    "_execute_",
    "_refresh_",
];
export function isMutatingToolName(toolName) {
    return ((toolName.startsWith("godot_runtime_") && toolName !== "godot_runtime_status") ||
        MUTATING_TOOL_KEYWORDS.some((keyword) => toolName.includes(keyword)) ||
        toolName === "godot_connect" ||
        toolName === "godot_disconnect" ||
        toolName === "godot_animation_build_state_machine_plan" ||
        toolName === "godot_animation_build_blend_space_plan");
}
export function usesEditorBridgeTool(toolName) {
    return (toolName.startsWith("godot_editor_") ||
        toolName.startsWith("godot_runtime_") ||
        toolName === "godot_connect" ||
        toolName === "godot_disconnect" ||
        toolName === "godot_connection_status");
}
export function requiresEditorBridgeConnection(toolName) {
    return ((toolName.startsWith("godot_editor_") || toolName.startsWith("godot_runtime_")) &&
        !toolName.includes("connection_status"));
}
//# sourceMappingURL=tool-metadata.js.map