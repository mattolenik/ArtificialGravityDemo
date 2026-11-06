/**
 * Input map tools for Godot MCP
 *
 * Provides helpers for reading and editing the [input] section in project.godot.
 */
import { z } from "zod";
import { splitGodotStatements } from "../parsers/godot-text.js";
import * as fs from "../utils/project-fs.js";
import { resolveProjectPath } from "../utils/path-utils.js";
const InputEventSchema = z.discriminatedUnion("type", [
    z.object({
        type: z.literal("key"),
        keycode: z.number().int().optional().describe("Logical keycode (Godot key enum int)"),
        physicalKeycode: z
            .number()
            .int()
            .optional()
            .describe("Physical keyboard keycode (preferred for gameplay actions)"),
        unicode: z.number().int().optional().describe("Unicode codepoint (defaults to 0)"),
        device: z.number().int().optional().default(-1).describe("Input device id (-1 for any)"),
        alt: z.boolean().optional().default(false),
        shift: z.boolean().optional().default(false),
        ctrl: z.boolean().optional().default(false),
        meta: z.boolean().optional().default(false),
    }),
    z.object({
        type: z.literal("mouse_button"),
        buttonIndex: z
            .number()
            .int()
            .min(1)
            .describe("Mouse button index (1=left, 2=right, 3=middle, 4=wheel up, 5=wheel down)"),
        device: z.number().int().optional().default(-1),
        doubleClick: z.boolean().optional().default(false),
    }),
    z.object({
        type: z.literal("joy_button"),
        buttonIndex: z.number().int().min(0).describe("Joypad button index"),
        device: z.number().int().optional().default(0),
    }),
    z.object({
        type: z.literal("joy_axis"),
        axis: z.number().int().min(0).describe("Joypad axis index"),
        axisValue: z.number().min(-1).max(1).describe("Axis direction (-1..1)"),
        device: z.number().int().optional().default(0),
    }),
    z.object({
        type: z.literal("raw"),
        raw: z
            .string()
            .min(1)
            .describe("Raw Godot InputEvent object literal (advanced/unsupported event types)"),
    }),
]);
export function registerInputTools(tools, state) {
    tools.set("godot_input_list_actions", {
        description: "List InputMap actions from project.godot with deadzones and binding counts.",
        inputSchema: z.object({
            includeEvents: z
                .boolean()
                .optional()
                .default(false)
                .describe("Include parsed event details for each action"),
        }),
        handler: async (args) => {
            const { includeEvents } = args;
            const { projectPath, content } = await readProjectFile(state.projectPath);
            const parsed = parseInputMapContent(content);
            return {
                projectPath,
                hasInputSection: parsed.hasInputSection,
                actionCount: parsed.actions.length,
                actions: includeEvents
                    ? parsed.actions
                    : parsed.actions.map((action) => ({
                        name: action.name,
                        deadzone: action.deadzone,
                        eventCount: action.events.length,
                    })),
            };
        },
    });
    tools.set("godot_input_get_action", {
        description: "Get a single InputMap action and its bindings from project.godot.",
        inputSchema: z.object({
            action: z.string().min(1).describe("Input action name"),
        }),
        handler: async (args) => {
            const { action } = args;
            const { projectPath, content } = await readProjectFile(state.projectPath);
            const parsed = parseInputMapContent(content);
            const found = parsed.actions.find((entry) => entry.name === action);
            if (!found) {
                return {
                    projectPath,
                    action,
                    found: false,
                    availableActions: parsed.actions.map((entry) => entry.name).sort(),
                };
            }
            return {
                projectPath,
                found: true,
                action: found,
            };
        },
    });
    tools.set("godot_input_set_action", {
        description: "Create or update an InputMap action in project.godot (replace or append bindings).",
        inputSchema: z.object({
            action: z.string().min(1).describe("Input action name"),
            deadzone: z
                .number()
                .min(0)
                .max(1)
                .optional()
                .describe("Action deadzone (defaults to existing or 0.5)"),
            events: z
                .array(InputEventSchema)
                .optional()
                .describe("Bindings to set or append"),
            replaceEvents: z
                .boolean()
                .optional()
                .default(true)
                .describe("Replace all existing bindings (true) or append new ones (false)"),
        }),
        handler: async (args) => {
            const { action, deadzone, events, replaceEvents } = args;
            const file = await readProjectFile(state.projectPath);
            const parsed = parseInputMapContent(file.content);
            const actionMap = new Map(parsed.actions.map((entry) => [entry.name, entry]));
            const existing = actionMap.get(action);
            const normalizedEvents = events?.map(normalizeEventForWrite);
            if (!existing && (!normalizedEvents || normalizedEvents.length === 0)) {
                throw new Error("New actions require at least one event binding. Provide `events` with one or more entries.");
            }
            const nextAction = {
                name: action,
                deadzone: deadzone ?? existing?.deadzone ?? 0.5,
                events: normalizedEvents
                    ? replaceEvents
                        ? normalizedEvents
                        : [...(existing?.events || []), ...normalizedEvents]
                    : existing?.events || [],
            };
            actionMap.set(action, nextAction);
            const nextContent = updateInputSection(file.content, Array.from(actionMap.values()).sort((a, b) => a.name.localeCompare(b.name)));
            await fs.writeFile(file.fullPath, nextContent, "utf-8");
            return {
                success: true,
                projectPath: file.projectPath,
                action: nextAction,
            };
        },
    });
    tools.set("godot_input_remove_action", {
        description: "Remove an InputMap action from project.godot.",
        inputSchema: z.object({
            action: z.string().min(1).describe("Input action name to remove"),
            errorIfMissing: z
                .boolean()
                .optional()
                .default(false)
                .describe("If true, throw when action does not exist"),
        }),
        handler: async (args) => {
            const { action, errorIfMissing } = args;
            const file = await readProjectFile(state.projectPath);
            const parsed = parseInputMapContent(file.content);
            const filtered = parsed.actions.filter((entry) => entry.name !== action);
            const removed = filtered.length !== parsed.actions.length;
            if (!removed && errorIfMissing) {
                throw new Error(`Input action not found: ${action}`);
            }
            if (removed) {
                const nextContent = updateInputSection(file.content, filtered);
                await fs.writeFile(file.fullPath, nextContent, "utf-8");
            }
            return {
                success: true,
                projectPath: file.projectPath,
                action,
                removed,
                actionCount: filtered.length,
            };
        },
    });
    tools.set("godot_input_list_presets", {
        description: "List built-in InputMap presets available for quick setup.",
        inputSchema: z.object({}),
        handler: async () => {
            return {
                presets: Object.entries(INPUT_PRESETS).map(([name, actions]) => ({
                    name,
                    actionCount: actions.length,
                    actions: actions.map((action) => action.name),
                })),
            };
        },
    });
    tools.set("godot_input_apply_preset", {
        description: "Apply a built-in InputMap preset to project.godot (merge or replace existing actions).",
        inputSchema: z.object({
            preset: z
                .enum(["2d_platformer", "2d_topdown", "3d_fps", "ui_menu"])
                .describe("Preset action set to apply"),
            merge: z
                .boolean()
                .optional()
                .default(true)
                .describe("Merge into existing actions (true) or replace all actions (false)"),
        }),
        handler: async (args) => {
            const { preset, merge } = args;
            const file = await readProjectFile(state.projectPath);
            const parsed = parseInputMapContent(file.content);
            const presetActions = INPUT_PRESETS[preset].map(cloneAction);
            let nextActions;
            if (merge) {
                const actionMap = new Map(parsed.actions.map((entry) => [entry.name, entry]));
                for (const action of presetActions) {
                    actionMap.set(action.name, action);
                }
                nextActions = Array.from(actionMap.values()).sort((a, b) => a.name.localeCompare(b.name));
            }
            else {
                nextActions = presetActions;
            }
            const nextContent = updateInputSection(file.content, nextActions);
            await fs.writeFile(file.fullPath, nextContent, "utf-8");
            return {
                success: true,
                projectPath: file.projectPath,
                preset,
                merge,
                actionCount: nextActions.length,
                appliedActions: presetActions.map((action) => action.name),
            };
        },
    });
}
async function readProjectFile(projectPath) {
    const fullPath = resolveProjectPath("project.godot", projectPath);
    let content;
    try {
        content = await fs.readFile(fullPath, "utf-8");
    }
    catch (error) {
        throw new Error("project.godot not found. Initialize a project first with `godot_init_project` or point --project to a valid Godot project.");
    }
    return {
        fullPath,
        projectPath: "res://project.godot",
        content,
    };
}
export function parseInputMapContent(content) {
    const extracted = extractInputSection(content);
    if (!extracted.exists) {
        return {
            hasInputSection: false,
            actions: [],
        };
    }
    return {
        hasInputSection: true,
        actions: parseInputActions(extracted.body),
    };
}
export function updateInputSection(content, actions) {
    const extracted = extractInputSection(content);
    const remaining = new Map(actions.map((action) => [action.name, action]));
    const lines = ["[input]"];
    for (const statement of splitGodotStatements(extracted.body)) {
        const match = statement.match(/^(.+?)\s*=\s*(\{[\s\S]*\})$/);
        if (!match) {
            lines.push(statement);
            continue;
        }
        const name = decodeActionName(match[1].trim());
        const action = remaining.get(name);
        if (!action)
            continue;
        remaining.delete(name);
        const previous = parseInputActionLiteral(name, match[2]);
        if (previous.deadzone === action.deadzone &&
            previous.events.map(serializeInputEvent).join(",") === action.events.map(serializeInputEvent).join(",")) {
            lines.push(statement);
            continue;
        }
        const fields = splitTopLevel(match[2].slice(1, -1), ",");
        const updates = new Map([
            ['"deadzone"', formatNumber(action.deadzone)],
            ['"events"', `[${action.events.map(serializeInputEvent).join(", ")}]`],
        ]);
        const nextFields = fields.map((field) => {
            const colon = findTopLevelSeparator(field, ":");
            const key = field.slice(0, colon).trim();
            if (colon < 0 || !updates.has(key))
                return field;
            const value = updates.get(key);
            updates.delete(key);
            return `${key}: ${value}`;
        });
        for (const [key, value] of updates)
            nextFields.push(`${key}: ${value}`);
        lines.push(`${match[1].trim()}={\n${nextFields.join(",\n")}\n}`);
    }
    for (const action of remaining.values()) {
        lines.push(serializeInputSection([action]).replace(/^\[input\]\n*/, ""));
    }
    return `${[extracted.before.trimEnd(), lines.join("\n"), extracted.after.trimStart()].filter(Boolean).join("\n\n").trimEnd()}\n`;
}
function decodeActionName(name) {
    return name.startsWith('"') ? JSON.parse(name) : name;
}
function encodeActionName(name) {
    return /^[a-zA-Z0-9_./-]+$/.test(name) ? name : JSON.stringify(name);
}
function extractInputSection(content) {
    // A section-like line inside a multiline Variant/string is not a header.
    let quoted = false;
    let escaped = false;
    let depth = 0;
    let offset = 0;
    let inputStart = -1;
    let bodyStart = -1;
    for (const line of content.split(/(?<=\n)/)) {
        const header = !quoted && depth === 0 ? line.trim().match(/^\[([^\]]+)\]\s*(?:;.*)?$/) : null;
        if (header) {
            if (inputStart >= 0)
                return { exists: true, before: content.slice(0, inputStart), body: content.slice(bodyStart, offset), after: content.slice(offset) };
            if (header[1] === "input") {
                inputStart = offset;
                bodyStart = offset + line.length;
            }
        }
        for (const char of line) {
            if (quoted) {
                if (escaped)
                    escaped = false;
                else if (char === "\\")
                    escaped = true;
                else if (char === '"')
                    quoted = false;
            }
            else if (char === ";")
                break;
            else if (char === '"')
                quoted = true;
            else if ("([{".includes(char))
                depth++;
            else if (")]}".includes(char))
                depth--;
        }
        offset += line.length;
    }
    if (inputStart < 0)
        return { exists: false, before: content, body: "", after: "" };
    return { exists: true, before: content.slice(0, inputStart), body: content.slice(bodyStart), after: "" };
}
function parseInputActions(body) {
    const actions = [];
    for (const statement of splitGodotStatements(body)) {
        const match = statement.match(/^(.+?)\s*=\s*(\{[\s\S]*\})$/);
        if (match)
            actions.push(parseInputActionLiteral(decodeActionName(match[1].trim()), match[2]));
    }
    return actions.sort((a, b) => a.name.localeCompare(b.name));
}
function parseInputActionLiteral(name, literal) {
    const fields = new Map();
    for (const field of splitTopLevel(literal.slice(1, -1), ",")) {
        const colon = findTopLevelSeparator(field, ":");
        if (colon < 0)
            throw new Error(`Invalid InputMap action dictionary: ${name}`);
        const rawKey = field.slice(0, colon).trim().replace(/^&/, "");
        const key = rawKey.startsWith('"') ? JSON.parse(rawKey) : rawKey;
        fields.set(key, field.slice(colon + 1).trim());
    }
    const deadzone = fields.has("deadzone") ? Number(fields.get("deadzone")) : 0.5;
    let eventsValue = fields.get("events") ?? "[]";
    // Godot may save a typed array; preserve the original event objects when appending.
    const typed = eventsValue.match(/^Array\[[^\]]+\]\(\s*([\s\S]*)\s*\)$/);
    if (typed)
        eventsValue = typed[1].trim();
    if (!eventsValue.startsWith("[") || !eventsValue.endsWith("]")) {
        throw new Error(`Unsupported events value for InputMap action '${name}'; refusing a lossy edit`);
    }
    return {
        name,
        deadzone: Number.isFinite(deadzone) ? deadzone : 0.5,
        events: splitTopLevel(eventsValue.slice(1, -1), ",").map(parseInputEvent),
    };
}
const originalEvents = new WeakMap();
function parseInputEvent(rawEvent) {
    const event = parseStructuredInputEvent(rawEvent);
    originalEvents.set(event, rawEvent.trim());
    return event;
}
function parseStructuredInputEvent(rawEvent) {
    const trimmed = rawEvent.trim();
    const objectMatch = trimmed.match(/^Object\(([^,\s)]+)\s*,(.*)\)$/);
    if (!objectMatch) {
        return { type: "raw", raw: trimmed };
    }
    const eventType = objectMatch[1].trim();
    const fields = parseObjectFields(objectMatch[2]);
    if (eventType === "InputEventKey") {
        return {
            type: "key",
            keycode: toInt(fields.keycode, 0),
            physicalKeycode: toInt(fields.physical_keycode, 0),
            unicode: toInt(fields.unicode, 0),
            device: toInt(fields.device, -1),
            alt: toBool(fields.alt_pressed, false),
            shift: toBool(fields.shift_pressed, false),
            ctrl: toBool(fields.ctrl_pressed, false),
            meta: toBool(fields.meta_pressed, false),
        };
    }
    if (eventType === "InputEventMouseButton") {
        return {
            type: "mouse_button",
            buttonIndex: toInt(fields.button_index, 1),
            device: toInt(fields.device, -1),
            doubleClick: toBool(fields.double_click, false),
        };
    }
    if (eventType === "InputEventJoypadButton") {
        return {
            type: "joy_button",
            buttonIndex: toInt(fields.button_index, 0),
            device: toInt(fields.device, 0),
        };
    }
    if (eventType === "InputEventJoypadMotion") {
        return {
            type: "joy_axis",
            axis: toInt(fields.axis, 0),
            axisValue: toFloat(fields.axis_value, 0),
            device: toInt(fields.device, 0),
        };
    }
    return { type: "raw", raw: trimmed };
}
function parseObjectFields(raw) {
    const fields = {};
    const segments = splitTopLevel(raw, ",");
    for (const segment of segments) {
        const separator = findTopLevelSeparator(segment, ":");
        if (separator === -1) {
            continue;
        }
        const rawKey = segment.slice(0, separator).trim();
        const rawValue = segment.slice(separator + 1).trim();
        if (!rawKey.startsWith('"') || !rawKey.endsWith('"')) {
            continue;
        }
        const key = rawKey.slice(1, -1);
        fields[key] = rawValue;
    }
    return fields;
}
function normalizeEventForWrite(event) {
    if (event.type === "raw") {
        return { type: "raw", raw: event.raw.trim() };
    }
    if (event.type === "key") {
        const keycode = event.keycode ?? event.physicalKeycode ?? 0;
        const physicalKeycode = event.physicalKeycode ?? event.keycode ?? 0;
        return {
            type: "key",
            keycode,
            physicalKeycode,
            unicode: event.unicode ?? 0,
            device: event.device ?? -1,
            alt: event.alt ?? false,
            shift: event.shift ?? false,
            ctrl: event.ctrl ?? false,
            meta: event.meta ?? false,
        };
    }
    if (event.type === "mouse_button") {
        return {
            type: "mouse_button",
            buttonIndex: event.buttonIndex,
            device: event.device ?? -1,
            doubleClick: event.doubleClick ?? false,
        };
    }
    if (event.type === "joy_button") {
        return {
            type: "joy_button",
            buttonIndex: event.buttonIndex,
            device: event.device ?? 0,
        };
    }
    return {
        type: "joy_axis",
        axis: event.axis,
        axisValue: event.axisValue,
        device: event.device ?? 0,
    };
}
function serializeInputSection(actions) {
    const lines = ["[input]", ""];
    for (const action of actions) {
        lines.push(`${encodeActionName(action.name)}={`);
        lines.push(`"deadzone": ${formatNumber(action.deadzone)},`);
        lines.push(`"events": [${action.events.map(serializeInputEvent).join(", ")}]`);
        lines.push("}");
    }
    return lines.join("\n");
}
function serializeInputEvent(event) {
    const original = originalEvents.get(event);
    if (original !== undefined)
        return original;
    if (event.type === "raw") {
        return event.raw;
    }
    if (event.type === "key") {
        return `Object(InputEventKey,"resource_local_to_scene":false,"resource_name":"","device":${event.device},"window_id":0,"alt_pressed":${event.alt ? "true" : "false"},"shift_pressed":${event.shift ? "true" : "false"},"ctrl_pressed":${event.ctrl ? "true" : "false"},"meta_pressed":${event.meta ? "true" : "false"},"pressed":false,"keycode":${event.keycode},"physical_keycode":${event.physicalKeycode},"key_label":0,"unicode":${event.unicode},"location":0,"echo":false,"script":null)`;
    }
    if (event.type === "mouse_button") {
        return `Object(InputEventMouseButton,"resource_local_to_scene":false,"resource_name":"","device":${event.device},"window_id":0,"alt_pressed":false,"shift_pressed":false,"ctrl_pressed":false,"meta_pressed":false,"button_mask":0,"position":Vector2(0, 0),"global_position":Vector2(0, 0),"factor":1.0,"button_index":${event.buttonIndex},"pressed":false,"canceled":false,"double_click":${event.doubleClick ? "true" : "false"},"script":null)`;
    }
    if (event.type === "joy_button") {
        return `Object(InputEventJoypadButton,"resource_local_to_scene":false,"resource_name":"","device":${event.device},"button_index":${event.buttonIndex},"pressure":0.0,"pressed":false,"script":null)`;
    }
    return `Object(InputEventJoypadMotion,"resource_local_to_scene":false,"resource_name":"","device":${event.device},"axis":${event.axis},"axis_value":${formatNumber(event.axisValue)},"script":null)`;
}
function cloneAction(action) {
    return {
        name: action.name,
        deadzone: action.deadzone,
        events: action.events.map((event) => {
            if (event.type === "raw") {
                return { type: "raw", raw: event.raw };
            }
            const copy = { ...event };
            const raw = originalEvents.get(event);
            if (raw !== undefined)
                originalEvents.set(copy, raw);
            return copy;
        }),
    };
}
function splitTopLevel(input, separator) {
    const result = [];
    let current = "";
    let inString = false;
    let parenDepth = 0;
    let bracketDepth = 0;
    let braceDepth = 0;
    for (let index = 0; index < input.length; index++) {
        const char = input[index];
        if (char === '"' && !isEscaped(input, index)) {
            inString = !inString;
        }
        if (!inString) {
            if (char === "(")
                parenDepth += 1;
            if (char === ")")
                parenDepth -= 1;
            if (char === "[")
                bracketDepth += 1;
            if (char === "]")
                bracketDepth -= 1;
            if (char === "{")
                braceDepth += 1;
            if (char === "}")
                braceDepth -= 1;
            if (char === separator &&
                parenDepth === 0 &&
                bracketDepth === 0 &&
                braceDepth === 0) {
                result.push(current.trim());
                current = "";
                continue;
            }
        }
        current += char;
    }
    if (current.trim()) {
        result.push(current.trim());
    }
    return result;
}
function findTopLevelSeparator(input, separator) {
    let inString = false;
    let parenDepth = 0;
    let bracketDepth = 0;
    let braceDepth = 0;
    for (let index = 0; index < input.length; index++) {
        const char = input[index];
        if (char === '"' && !isEscaped(input, index)) {
            inString = !inString;
        }
        if (!inString) {
            if (char === "(")
                parenDepth += 1;
            if (char === ")")
                parenDepth -= 1;
            if (char === "[")
                bracketDepth += 1;
            if (char === "]")
                bracketDepth -= 1;
            if (char === "{")
                braceDepth += 1;
            if (char === "}")
                braceDepth -= 1;
            if (char === separator &&
                parenDepth === 0 &&
                bracketDepth === 0 &&
                braceDepth === 0) {
                return index;
            }
        }
    }
    return -1;
}
function toInt(value, fallback) {
    if (!value)
        return fallback;
    const parsed = parseInt(value, 10);
    return Number.isFinite(parsed) ? parsed : fallback;
}
function toFloat(value, fallback) {
    if (!value)
        return fallback;
    const parsed = parseFloat(value);
    return Number.isFinite(parsed) ? parsed : fallback;
}
function toBool(value, fallback) {
    if (!value)
        return fallback;
    if (value === "true")
        return true;
    if (value === "false")
        return false;
    return fallback;
}
function formatNumber(value) {
    if (Number.isInteger(value)) {
        return String(value);
    }
    return Number(value.toFixed(6)).toString();
}
const INPUT_PRESETS = {
    "2d_platformer": [
        keyAction("move_left", [65]),
        keyAction("move_right", [68]),
        keyAction("jump", [32]),
    ],
    "2d_topdown": [
        keyAction("move_left", [65]),
        keyAction("move_right", [68]),
        keyAction("move_up", [87]),
        keyAction("move_down", [83]),
        keyAction("interact", [69]),
    ],
    "3d_fps": [
        keyAction("move_left", [65]),
        keyAction("move_right", [68]),
        keyAction("move_forward", [87]),
        keyAction("move_back", [83]),
        keyAction("jump", [32]),
        {
            name: "fire",
            deadzone: 0.5,
            events: [{ type: "mouse_button", buttonIndex: 1, device: -1, doubleClick: false }],
        },
        {
            name: "aim",
            deadzone: 0.5,
            events: [{ type: "mouse_button", buttonIndex: 2, device: -1, doubleClick: false }],
        },
    ],
    "ui_menu": [
        keyAction("ui_accept", [13, 32]),
        keyAction("ui_cancel", [27]),
        keyAction("ui_left", [16777231, 65]),
        keyAction("ui_right", [16777233, 68]),
        keyAction("ui_up", [16777232, 87]),
        keyAction("ui_down", [16777234, 83]),
    ],
};
function keyAction(name, keys, deadzone = 0.5) {
    return {
        name,
        deadzone,
        events: keys.map((keycode) => ({
            type: "key",
            keycode,
            physicalKeycode: keycode,
            unicode: keycode < 256 ? keycode : 0,
            device: -1,
            alt: false,
            shift: false,
            ctrl: false,
            meta: false,
        })),
    };
}
function isEscaped(input, index) {
    let slashes = 0;
    while (index > 0 && input[--index] === "\\")
        slashes++;
    return slashes % 2 === 1;
}
//# sourceMappingURL=input-tools.js.map