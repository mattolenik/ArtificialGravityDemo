/**
 * Audio tools for Godot MCP
 *
 * Supports AudioBusLayout resource workflows and AudioStreamPlayer scene wiring.
 */
import { z } from "zod";
import { splitGodotStatements } from "../parsers/godot-text.js";
import * as fs from "../utils/project-fs.js";
import * as path from "path";
import { TscnParser } from "../parsers/tscn-parser.js";
import { getProjectRelativePath, resolveProjectPath } from "../utils/path-utils.js";
import { getSceneNodePath, normalizeSceneNodePath, } from "../utils/scene-path-utils.js";
const DEFAULT_BUS_LAYOUT_PATH = "res://default_bus_layout.tres";
const BusSchema = z.object({
    name: z.string().min(1).describe("Bus name"),
    send: z.string().optional().default("Master").describe("Target bus name"),
    volumeDb: z
        .number()
        .optional()
        .default(0)
        .describe("Bus volume in decibels"),
    mute: z.boolean().optional().default(false).describe("Mute bus"),
    solo: z.boolean().optional().default(false).describe("Solo bus"),
    bypassFx: z
        .boolean()
        .optional()
        .default(false)
        .describe("Bypass effects on this bus"),
});
const AUDIO_EFFECT_PRESETS = {
    "sfx_punch": {
        description: "Transient-focused SFX chain for impact-heavy effects.",
        chain: [
            { type: "AudioEffectCompressor", properties: { threshold: -8, ratio: 4.0 } },
            { type: "AudioEffectEQ6", properties: { "band_3_gain_db": 1.5 } },
            { type: "AudioEffectLimiter", properties: { ceiling_db: -0.5 } },
        ],
    },
    "music_warmth": {
        description: "Warm music chain with mild compression and low-pass color.",
        chain: [
            { type: "AudioEffectEQ10", properties: { "band_1_gain_db": 1.0, "band_8_gain_db": -1.0 } },
            { type: "AudioEffectCompressor", properties: { threshold: -14, ratio: 2.0 } },
            { type: "AudioEffectLimiter", properties: { ceiling_db: -1.0 } },
        ],
    },
    "dialog_clarity": {
        description: "Voice/dialog chain prioritizing intelligibility.",
        chain: [
            { type: "AudioEffectEQ6", properties: { "band_2_gain_db": -1.0, "band_4_gain_db": 2.0 } },
            { type: "AudioEffectCompressor", properties: { threshold: -12, ratio: 3.0 } },
            { type: "AudioEffectLimiter", properties: { ceiling_db: -1.0 } },
        ],
    },
};
const AUDIO_MIX_PROFILES = {
    gameplay: {
        description: "Balanced gameplay mix with slightly elevated SFX.",
        buses: [
            { name: "Music", volumeDb: -4, mute: false, solo: false },
            { name: "SFX", volumeDb: -1, mute: false, solo: false },
            { name: "VO", volumeDb: -2, mute: false, solo: false },
        ],
    },
    cinematic: {
        description: "Cinematic emphasis with louder music and dialog.",
        buses: [
            { name: "Music", volumeDb: -1, mute: false, solo: false },
            { name: "SFX", volumeDb: -6, mute: false, solo: false },
            { name: "VO", volumeDb: 0, mute: false, solo: false },
        ],
    },
    paused: {
        description: "Muted action mix intended for pause/menu overlays.",
        buses: [
            { name: "Music", volumeDb: -10, mute: false, solo: false },
            { name: "SFX", volumeDb: -20, mute: false, solo: false },
            { name: "VO", volumeDb: -12, mute: false, solo: false },
        ],
    },
    silent: {
        description: "Emergency silent mix profile.",
        buses: [
            { name: "Music", volumeDb: -80, mute: true, solo: false },
            { name: "SFX", volumeDb: -80, mute: true, solo: false },
            { name: "VO", volumeDb: -80, mute: true, solo: false },
        ],
    },
};
export function registerAudioTools(tools, state) {
    tools.set("godot_audio_create_bus_layout", {
        description: "Create or overwrite an AudioBusLayout (.tres) with named buses and routing.",
        inputSchema: z.object({
            path: z
                .string()
                .optional()
                .default(DEFAULT_BUS_LAYOUT_PATH)
                .describe("AudioBusLayout output path"),
            buses: z
                .array(BusSchema)
                .optional()
                .default([
                { name: "Music", send: "Master", volumeDb: 0, mute: false, solo: false, bypassFx: false },
                { name: "SFX", send: "Master", volumeDb: 0, mute: false, solo: false, bypassFx: false },
            ])
                .describe("Bus definitions to write"),
            setAsProjectDefault: z
                .boolean()
                .optional()
                .default(true)
                .describe("Set this layout as project default in project.godot"),
        }),
        handler: async (args) => {
            const { path: layoutPath, buses, setAsProjectDefault } = args;
            const normalizedBuses = normalizeBuses(buses);
            const resPath = toResPath(layoutPath, state.projectPath);
            const fullPath = resolveProjectPath(resPath, state.projectPath);
            const content = serializeAudioBusLayoutContent(normalizedBuses);
            await fs.mkdir(path.dirname(fullPath), { recursive: true });
            await fs.writeFile(fullPath, content, "utf-8");
            let projectUpdated = false;
            let warning;
            if (setAsProjectDefault) {
                const updateResult = await trySetProjectDefaultBusLayout(state.projectPath, resPath);
                projectUpdated = updateResult.updated;
                warning = updateResult.warning;
            }
            return {
                success: true,
                path: resPath,
                busCount: normalizedBuses.length,
                buses: normalizedBuses.map((bus) => bus.name),
                projectDefaultUpdated: projectUpdated,
                warning,
            };
        },
    });
    tools.set("godot_audio_read_bus_layout", {
        description: "Read an AudioBusLayout (.tres) and return structured bus data.",
        inputSchema: z.object({
            path: z
                .string()
                .optional()
                .describe("AudioBusLayout path (defaults to project default bus layout)"),
        }),
        handler: async (args) => {
            const { path: inputPath } = args;
            const resPath = inputPath || (await getProjectDefaultBusLayoutPath(state.projectPath));
            const fullPath = resolveProjectPath(resPath, state.projectPath);
            const content = await fs.readFile(fullPath, "utf-8");
            const buses = parseAudioBusLayoutContent(content);
            return {
                path: resPath,
                busCount: buses.length,
                buses,
            };
        },
    });
    tools.set("godot_audio_set_bus", {
        description: "Create or update a bus entry in an AudioBusLayout (.tres).",
        inputSchema: z.object({
            path: z
                .string()
                .optional()
                .describe("AudioBusLayout path (defaults to project default bus layout)"),
            name: z.string().min(1).describe("Bus name to create or update"),
            send: z.string().optional().describe("Target send bus"),
            volumeDb: z.number().optional().describe("Volume in dB"),
            mute: z.boolean().optional().describe("Mute state"),
            solo: z.boolean().optional().describe("Solo state"),
            bypassFx: z.boolean().optional().describe("Bypass effects state"),
            createIfMissing: z
                .boolean()
                .optional()
                .default(true)
                .describe("Create bus if not present"),
        }),
        handler: async (args) => {
            const { path: inputPath, name, send, volumeDb, mute, solo, bypassFx, createIfMissing, } = args;
            const resPath = inputPath || (await getProjectDefaultBusLayoutPath(state.projectPath));
            const fullPath = resolveProjectPath(resPath, state.projectPath);
            const originalContent = await readBusLayoutTextIfPresent(fullPath);
            const existing = originalContent ? parseAudioBusLayoutContent(originalContent) : [];
            const index = existing.findIndex((bus) => bus.name === name);
            if (index === -1 && !createIfMissing) {
                throw new Error(`Bus '${name}' not found and createIfMissing=false`);
            }
            if (index === -1) {
                existing.push({
                    name,
                    send: send || "Master",
                    volumeDb: volumeDb ?? 0,
                    mute: mute ?? false,
                    solo: solo ?? false,
                    bypassFx: bypassFx ?? false,
                });
            }
            else {
                const current = existing[index];
                existing[index] = {
                    name,
                    send: send ?? current.send,
                    volumeDb: volumeDb ?? current.volumeDb,
                    mute: mute ?? current.mute,
                    solo: solo ?? current.solo,
                    bypassFx: bypassFx ?? current.bypassFx,
                };
            }
            const normalized = normalizeBuses(existing);
            await fs.mkdir(path.dirname(fullPath), { recursive: true });
            await fs.writeFile(fullPath, updateAudioBusLayoutContent(originalContent, normalized), "utf-8");
            return {
                success: true,
                path: resPath,
                updatedBus: normalized.find((bus) => bus.name === name),
                busCount: normalized.length,
            };
        },
    });
    tools.set("godot_audio_remove_bus", {
        description: "Remove a bus from an AudioBusLayout (.tres) by name.",
        inputSchema: z.object({
            path: z
                .string()
                .optional()
                .describe("AudioBusLayout path (defaults to project default bus layout)"),
            name: z.string().min(1).describe("Bus name to remove"),
            errorIfMissing: z
                .boolean()
                .optional()
                .default(false)
                .describe("Throw error if the bus does not exist"),
        }),
        handler: async (args) => {
            const { path: inputPath, name, errorIfMissing } = args;
            const resPath = inputPath || (await getProjectDefaultBusLayoutPath(state.projectPath));
            const fullPath = resolveProjectPath(resPath, state.projectPath);
            if (name === "Master") {
                throw new Error("Cannot remove 'Master' bus");
            }
            const originalContent = await readBusLayoutTextIfPresent(fullPath);
            const existing = originalContent ? parseAudioBusLayoutContent(originalContent) : [];
            const filtered = existing.filter((bus) => bus.name !== name);
            const removed = filtered.length !== existing.length;
            if (!removed && errorIfMissing) {
                throw new Error(`Bus '${name}' not found`);
            }
            if (removed) {
                const normalized = normalizeBuses(filtered);
                await fs.writeFile(fullPath, updateAudioBusLayoutContent(originalContent, normalized), "utf-8");
            }
            return {
                success: true,
                path: resPath,
                name,
                removed,
                busCount: filtered.length,
            };
        },
    });
    tools.set("godot_audio_list_players", {
        description: "List AudioStreamPlayer nodes in a scene and their current bus/stream settings.",
        inputSchema: z.object({
            scenePath: z.string().describe("Path to scene file"),
            includeProperties: z
                .boolean()
                .optional()
                .default(true)
                .describe("Include key audio properties per node"),
        }),
        handler: async (args) => {
            const { scenePath, includeProperties } = args;
            const fullPath = resolveProjectPath(scenePath, state.projectPath);
            const content = await fs.readFile(fullPath, "utf-8");
            const scene = TscnParser.parse(content);
            const players = scene.nodes
                .filter((node) => isAudioPlayerNode(node))
                .map((node) => {
                const nodePath = getSceneNodePath(node);
                const stream = resolveStreamPath(scene, node);
                const base = { nodePath, type: node.type || "Unknown" };
                if (!includeProperties) {
                    return base;
                }
                return {
                    ...base,
                    stream,
                    bus: stringifySceneValue(node.properties.bus) || "Master",
                    volumeDb: numberOrUndefined(node.properties.volume_db),
                    pitchScale: numberOrUndefined(node.properties.pitch_scale),
                    autoplay: boolOrUndefined(node.properties.autoplay),
                };
            });
            return {
                scenePath,
                playerCount: players.length,
                players,
            };
        },
    });
    tools.set("godot_audio_configure_player", {
        description: "Configure an AudioStreamPlayer node in a scene (stream, bus, volume, pitch, autoplay).",
        inputSchema: z.object({
            scenePath: z.string().describe("Path to scene file"),
            nodePath: z.string().describe("Target node path"),
            streamPath: z
                .string()
                .optional()
                .describe("Audio stream resource path (ogg/wav/mp3/etc.)"),
            bus: z.string().optional().describe("Target audio bus name"),
            volumeDb: z.number().optional().describe("Volume in decibels"),
            pitchScale: z.number().optional().describe("Pitch multiplier"),
            autoplay: z.boolean().optional().describe("Autoplay on scene start"),
        }),
        handler: async (args) => {
            const { scenePath, nodePath, streamPath, bus, volumeDb, pitchScale, autoplay } = args;
            if (streamPath === undefined &&
                bus === undefined &&
                volumeDb === undefined &&
                pitchScale === undefined &&
                autoplay === undefined) {
                throw new Error("Provide at least one property to configure");
            }
            const fullPath = resolveProjectPath(scenePath, state.projectPath);
            const content = await fs.readFile(fullPath, "utf-8");
            const scene = TscnParser.parse(content);
            const normalizedNodePath = normalizeSceneNodePath(scene, nodePath);
            const node = scene.nodes.find((entry) => getSceneNodePath(entry) === normalizedNodePath);
            if (!node) {
                throw new Error(`Node not found: ${nodePath}`);
            }
            if (!isAudioPlayerNode(node)) {
                throw new Error(`Node '${normalizedNodePath}' is not an AudioStreamPlayer node (found type '${node.type || "unknown"}')`);
            }
            const updates = {};
            if (streamPath) {
                const streamResPath = toResPath(streamPath, state.projectPath);
                const streamType = inferStreamType(streamResPath);
                const extResourceId = ensureExternalResource(scene, streamType, streamResPath);
                updates.stream = { _type: "ExtResource", id: extResourceId };
            }
            if (bus !== undefined) {
                updates.bus = bus;
            }
            if (volumeDb !== undefined) {
                updates.volume_db = volumeDb;
            }
            if (pitchScale !== undefined) {
                updates.pitch_scale = pitchScale;
            }
            if (autoplay !== undefined) {
                updates.autoplay = autoplay;
            }
            const changed = TscnParser.modifyNode(scene, normalizedNodePath, {
                properties: updates,
            });
            if (!changed) {
                throw new Error(`Failed to modify node: ${normalizedNodePath}`);
            }
            await fs.writeFile(fullPath, TscnParser.serialize(scene), "utf-8");
            return {
                success: true,
                scenePath,
                nodePath: normalizedNodePath,
                updatedProperties: Object.keys(updates),
            };
        },
    });
    tools.set("godot_audio_list_effect_presets", {
        description: "List built-in audio effect chain presets for common mixing goals.",
        inputSchema: z.object({}),
        handler: async () => ({
            presets: Object.entries(AUDIO_EFFECT_PRESETS).map(([name, preset]) => ({
                name,
                description: preset.description,
                effectTypes: preset.chain.map((effect) => effect.type),
                effectCount: preset.chain.length,
            })),
        }),
    });
    tools.set("godot_audio_generate_effect_chain_script", {
        description: "Generate a GDScript snippet to apply an effect-chain preset to a bus via AudioServer.",
        inputSchema: z.object({
            preset: z
                .enum(["sfx_punch", "music_warmth", "dialog_clarity"])
                .describe("Effect-chain preset"),
            busName: z.string().describe("Target bus name"),
            clearExisting: z
                .boolean()
                .optional()
                .default(true)
                .describe("Remove existing effects before applying preset"),
        }),
        handler: async (args) => {
            const { preset, busName, clearExisting } = args;
            const script = buildEffectChainScript(preset, busName, clearExisting);
            return {
                preset,
                busName,
                clearExisting,
                script,
                tip: "Run this via `godot_editor_execute_gdscript` when connected to the editor.",
            };
        },
    });
    tools.set("godot_audio_apply_mix_profile", {
        description: "Apply a named mix profile to bus levels/mute/solo values in an AudioBusLayout.",
        inputSchema: z.object({
            path: z
                .string()
                .optional()
                .describe("AudioBusLayout path (defaults to project default bus layout)"),
            profile: z
                .enum(["gameplay", "cinematic", "paused", "silent"])
                .describe("Mix profile to apply"),
            createMissingBuses: z
                .boolean()
                .optional()
                .default(true)
                .describe("Create buses referenced by profile if missing"),
        }),
        handler: async (args) => {
            const { path: inputPath, profile, createMissingBuses } = args;
            const resPath = inputPath || (await getProjectDefaultBusLayoutPath(state.projectPath));
            const fullPath = resolveProjectPath(resPath, state.projectPath);
            const originalContent = await readBusLayoutTextIfPresent(fullPath);
            const existing = originalContent ? parseAudioBusLayoutContent(originalContent) : [];
            const profileData = AUDIO_MIX_PROFILES[profile];
            const result = applyMixProfileToBuses(existing, profileData.buses, createMissingBuses);
            const normalized = normalizeBuses(result.buses);
            await fs.mkdir(path.dirname(fullPath), { recursive: true });
            await fs.writeFile(fullPath, updateAudioBusLayoutContent(originalContent, normalized), "utf-8");
            return {
                success: true,
                path: resPath,
                profile,
                description: profileData.description,
                applied: result.applied,
                created: result.created,
                busCount: normalized.length,
            };
        },
    });
}
export function serializeAudioBusLayoutContent(buses) {
    const lines = [];
    lines.push('[gd_resource type="AudioBusLayout" format=3]');
    lines.push("");
    lines.push("[resource]");
    const normalized = normalizeBuses(buses);
    const startsAtZero = normalized.length > 0 && normalized[0].name === "Master";
    normalized.forEach((bus, index) => {
        const busIndex = startsAtZero ? index : index + 1;
        lines.push(`bus/${busIndex}/name = &"${escapeString(bus.name)}"`);
        lines.push(`bus/${busIndex}/solo = ${bus.solo ? "true" : "false"}`);
        lines.push(`bus/${busIndex}/mute = ${bus.mute ? "true" : "false"}`);
        lines.push(`bus/${busIndex}/bypass_fx = ${bus.bypassFx ? "true" : "false"}`);
        lines.push(`bus/${busIndex}/volume_db = ${formatNumber(bus.volumeDb)}`);
        lines.push(`bus/${busIndex}/send = &"${escapeString(bus.send)}"`);
    });
    return `${lines.join("\n")}\n`;
}
export function parseAudioBusLayoutContent(content) {
    const map = new Map();
    const statements = audioStatements(content);
    const resourceIndex = statements.indexOf("[resource]");
    const chunks = resourceIndex >= 0 ? statements.slice(resourceIndex + 1) : statements;
    for (const chunk of chunks) {
        const line = chunk.trim();
        if (!line.startsWith("bus/"))
            continue;
        const match = line.match(/^bus\/(\d+)\/([^=]+?)\s*=\s*(.+)$/s);
        if (!match)
            continue;
        const index = parseInt(match[1], 10);
        const key = match[2];
        const rawValue = match[3].trim();
        const current = map.get(index) || {};
        if (key === "name")
            current.name = parseStringName(rawValue);
        if (key === "send")
            current.send = parseStringName(rawValue);
        if (key === "volume_db")
            current.volumeDb = parseFloatSafe(rawValue, 0);
        if (key === "mute")
            current.mute = parseBool(rawValue, false);
        if (key === "solo")
            current.solo = parseBool(rawValue, false);
        if (key === "bypass_fx")
            current.bypassFx = parseBool(rawValue, false);
        map.set(index, current);
    }
    return Array.from(map.entries())
        .sort((a, b) => a[0] - b[0])
        .map(([index, bus]) => ({
        name: bus.name || (index === 0 ? "Master" : `Bus${index}`),
        send: bus.send || "Master",
        volumeDb: bus.volumeDb ?? 0,
        mute: bus.mute ?? false,
        solo: bus.solo ?? false,
        bypassFx: bus.bypassFx ?? false,
    }));
}
export function setDefaultBusLayoutInProject(projectContent, layoutResPath) {
    return upsertProjectSectionSetting(projectContent, "audio", "buses/default_bus_layout", `"${layoutResPath}"`);
}
export function getDefaultBusLayoutFromProject(projectContent) {
    return readProjectSectionSetting(projectContent, "audio", "buses/default_bus_layout");
}
async function trySetProjectDefaultBusLayout(projectPath, layoutResPath) {
    const projectFilePath = resolveProjectPath("project.godot", projectPath);
    try {
        const content = await fs.readFile(projectFilePath, "utf-8");
        const updated = setDefaultBusLayoutInProject(content, layoutResPath);
        await fs.writeFile(projectFilePath, updated, "utf-8");
        return { updated: true };
    }
    catch {
        return {
            updated: false,
            warning: "project.godot not found; layout was created but project default bus layout could not be updated",
        };
    }
}
async function getProjectDefaultBusLayoutPath(projectPath) {
    const projectFilePath = resolveProjectPath("project.godot", projectPath);
    try {
        const content = await fs.readFile(projectFilePath, "utf-8");
        return getDefaultBusLayoutFromProject(content) || DEFAULT_BUS_LAYOUT_PATH;
    }
    catch {
        return DEFAULT_BUS_LAYOUT_PATH;
    }
}
async function readBusLayoutTextIfPresent(fullPath) {
    try {
        return await fs.readFile(fullPath, "utf-8");
    }
    catch (error) {
        if (error.code === "ENOENT")
            return null;
        throw error;
    }
}
/** Keep the full resource document, including unknown fields and effect resources.
 * Only bus assignments are edited/reindexed; unused subresources remain harmless.
 */
export function updateAudioBusLayoutContent(content, buses) {
    if (content === null)
        return serializeAudioBusLayoutContent(buses);
    const statements = audioStatements(content);
    if (!/^\[gd_resource\b[^\]]*type="AudioBusLayout"/.test(statements[0] || "")) {
        throw new Error("Expected an AudioBusLayout resource; refusing to overwrite it");
    }
    const resourceIndex = statements.findIndex((statement) => statement === "[resource]");
    if (resourceIndex < 0)
        throw new Error("AudioBusLayout is missing its resource section");
    const originalNames = new Map();
    for (const statement of statements.slice(resourceIndex + 1)) {
        const match = statement.match(/^bus\/(\d+)\/name\s*=\s*(.+)$/s);
        if (match)
            originalNames.set(Number(match[1]), parseStringName(match[2]));
    }
    // Godot can omit the default Master name while retaining its volume/effects.
    if (!originalNames.has(0))
        originalNames.set(0, "Master");
    const normalized = normalizeBuses(buses);
    const startsAtZero = normalized[0]?.name === "Master";
    const newIndices = new Map(normalized.map((bus, index) => [bus.name, index + (startsAtZero ? 0 : 1)]));
    if (!newIndices.has("Master"))
        newIndices.set("Master", 0);
    const removedNames = new Set([...originalNames.values()].filter((name) => !newIndices.has(name)));
    const values = new Map();
    for (const statement of splitGodotStatements(serializeAudioBusLayoutContent(normalized))) {
        const match = statement.match(/^(bus\/\d+\/[^=]+?)\s*=\s*(.+)$/s);
        if (match)
            values.set(match[1], match[2]);
    }
    const result = statements.slice(0, resourceIndex + 1);
    for (const statement of statements.slice(resourceIndex + 1)) {
        const match = statement.match(/^bus\/(\d+)\/([^=]+?)\s*=\s*(.+)$/s);
        if (!match) {
            result.push(statement);
            continue;
        }
        const name = originalNames.get(Number(match[1]));
        if (!name)
            throw new Error(`Cannot safely identify audio bus ${match[1]}`);
        const nextIndex = newIndices.get(name);
        if (nextIndex === undefined)
            continue; // Remove this bus's assignments only.
        const key = `bus/${nextIndex}/${match[2]}`;
        let value = values.get(key) ?? match[3];
        if (match[2] === "send" && removedNames.has(parseStringName(value))) {
            value = '&"Master"';
        }
        result.push(`${key} = ${value}`);
        values.delete(key);
    }
    for (const [key, value] of values)
        result.push(`${key} = ${value}`);
    return `${result.join("\n")}\n`;
}
export function buildEffectChainScript(presetName, busName, clearExisting) {
    const preset = AUDIO_EFFECT_PRESETS[presetName];
    const lines = [];
    lines.push("# Generated by godot_audio_generate_effect_chain_script");
    lines.push(`var bus_name := "${escapeString(busName)}"`);
    lines.push("var bus_idx := AudioServer.get_bus_index(bus_name)");
    lines.push('if bus_idx == -1:');
    lines.push('\tpush_error("Bus not found: %s" % bus_name)');
    lines.push("\treturn");
    lines.push("");
    if (clearExisting) {
        lines.push("while AudioServer.get_bus_effect_count(bus_idx) > 0:");
        lines.push('\tAudioServer.remove_bus_effect(bus_idx, AudioServer.get_bus_effect_count(bus_idx) - 1)');
        lines.push("");
    }
    preset.chain.forEach((effect, effectIndex) => {
        const varName = `effect_${effectIndex}`;
        lines.push(`var ${varName} := ${effect.type}.new()`);
        for (const [key, value] of Object.entries(effect.properties)) {
            lines.push(`${varName}.${key} = ${toGdScriptValue(value)}`);
        }
        lines.push(`AudioServer.add_bus_effect(bus_idx, ${varName})`);
        lines.push("");
    });
    lines.push(`print("Applied preset '${presetName}' (${preset.chain.length} effects) to bus: %s" % bus_name)`);
    return lines.join("\n");
}
export function applyMixProfileToBuses(buses, overrides, createMissingBuses) {
    const next = [...buses];
    const applied = [];
    const created = [];
    for (const override of overrides) {
        const idx = next.findIndex((bus) => bus.name === override.name);
        if (idx === -1) {
            if (!createMissingBuses) {
                continue;
            }
            next.push({
                name: override.name,
                send: "Master",
                volumeDb: override.volumeDb,
                mute: override.mute ?? false,
                solo: override.solo ?? false,
                bypassFx: override.bypassFx ?? false,
            });
            applied.push(override.name);
            created.push(override.name);
            continue;
        }
        const existing = next[idx];
        next[idx] = {
            ...existing,
            volumeDb: override.volumeDb,
            mute: override.mute ?? existing.mute,
            solo: override.solo ?? existing.solo,
            bypassFx: override.bypassFx ?? existing.bypassFx,
        };
        applied.push(override.name);
    }
    return { buses: next, applied, created };
}
function normalizeBuses(input) {
    const seenNames = new Set();
    const normalized = [];
    let masterBus = null;
    for (const bus of input) {
        const trimmedName = bus.name.trim();
        if (!trimmedName) {
            throw new Error("Bus name cannot be empty");
        }
        if (seenNames.has(trimmedName)) {
            throw new Error(`Duplicate bus name: ${trimmedName}`);
        }
        seenNames.add(trimmedName);
        const normalizedBus = {
            name: trimmedName,
            send: trimmedName === "Master" ? "" : bus.send.trim() || "Master",
            volumeDb: bus.volumeDb,
            mute: bus.mute,
            solo: bus.solo,
            bypassFx: bus.bypassFx,
        };
        if (trimmedName === "Master") {
            masterBus = normalizedBus;
            continue;
        }
        normalized.push(normalizedBus);
    }
    if (masterBus) {
        return [masterBus, ...normalized];
    }
    return normalized;
}
function ensureExternalResource(scene, type, resourcePath) {
    const existing = scene.externalResources.find((res) => res.path === resourcePath);
    if (existing) {
        return existing.id;
    }
    const id = nextExtResourceId(scene);
    scene.externalResources.push({ type, path: resourcePath, id });
    scene.header.loadSteps = scene.externalResources.length + scene.subResources.length + 1;
    return id;
}
function nextExtResourceId(scene) {
    const numericIds = scene.externalResources
        .map((res) => parseInt(res.id, 10))
        .filter((id) => Number.isFinite(id));
    if (numericIds.length === 0) {
        return "1";
    }
    return String(Math.max(...numericIds) + 1);
}
function isAudioPlayerNode(node) {
    return (node.type === "AudioStreamPlayer" ||
        node.type === "AudioStreamPlayer2D" ||
        node.type === "AudioStreamPlayer3D");
}
function resolveStreamPath(scene, node) {
    const streamValue = node.properties.stream;
    if (!streamValue)
        return null;
    if (typeof streamValue === "object" && streamValue !== null) {
        const ref = streamValue;
        if (ref._type === "ExtResource" && typeof ref.id === "string") {
            const ext = scene.externalResources.find((entry) => entry.id === ref.id);
            return ext?.path || `ExtResource("${ref.id}")`;
        }
    }
    return stringifySceneValue(streamValue);
}
function inferStreamType(resPath) {
    const lower = resPath.toLowerCase();
    if (lower.endsWith(".ogg"))
        return "AudioStreamOggVorbis";
    if (lower.endsWith(".wav"))
        return "AudioStreamWAV";
    if (lower.endsWith(".mp3"))
        return "AudioStreamMP3";
    return "AudioStream";
}
function toResPath(inputPath, projectPath) {
    const fullPath = resolveProjectPath(inputPath, projectPath);
    const relative = getProjectRelativePath(fullPath, projectPath).replace(/\\/g, "/");
    return `res://${relative}`;
}
function stringifySceneValue(value) {
    if (value === null || value === undefined)
        return null;
    if (typeof value === "string")
        return value;
    if (typeof value === "number" || typeof value === "boolean")
        return String(value);
    if (typeof value === "object") {
        const literal = value;
        if (literal._type === "Raw" && typeof literal.value === "string") {
            // The scene parser preserves StringName and unknown Variants as Raw.
            // Expose the bus name, not the parser's internal representation.
            return literal.value.trim().startsWith('&"')
                ? parseStringName(literal.value)
                : literal.value;
        }
        return JSON.stringify(value);
    }
    return String(value);
}
function numberOrUndefined(value) {
    if (typeof value === "number") {
        return value;
    }
    if (typeof value === "string") {
        const parsed = Number(value);
        return Number.isFinite(parsed) ? parsed : undefined;
    }
    return undefined;
}
function boolOrUndefined(value) {
    if (typeof value === "boolean")
        return value;
    if (typeof value === "string") {
        if (value === "true")
            return true;
        if (value === "false")
            return false;
    }
    return undefined;
}
function parseStringName(raw) {
    const trimmed = raw.trim().replace(/^&/, "");
    if (trimmed.startsWith('"')) {
        try {
            return JSON.parse(trimmed);
        }
        catch {
            throw new Error(`Invalid quoted bus name: ${raw}`);
        }
    }
    return trimmed;
}
// Accept legacy compact fixtures while never splitting inside a quoted name or Variant.
function audioStatements(content) {
    return splitGodotStatements(content).flatMap((statement) => {
        if (!statement.startsWith("bus/"))
            return [statement];
        const parts = [];
        let quoted = false;
        let escaped = false;
        let depth = 0;
        let start = 0;
        for (let index = 0; index < statement.length; index++) {
            const char = statement[index];
            if (quoted) {
                if (escaped)
                    escaped = false;
                else if (char === "\\")
                    escaped = true;
                else if (char === '"')
                    quoted = false;
                continue;
            }
            if (char === '"')
                quoted = true;
            else if ("([{".includes(char))
                depth++;
            else if (")]}".includes(char))
                depth--;
            else if (depth === 0 && /\s/.test(char) && /^bus\/\d+\//.test(statement.slice(index + 1))) {
                parts.push(statement.slice(start, index).trim());
                start = index + 1;
            }
        }
        parts.push(statement.slice(start).trim());
        return parts;
    });
}
function parseBool(raw, fallback) {
    if (raw === "true")
        return true;
    if (raw === "false")
        return false;
    return fallback;
}
function parseFloatSafe(raw, fallback) {
    const parsed = parseFloat(raw);
    return Number.isFinite(parsed) ? parsed : fallback;
}
function formatNumber(value) {
    if (Number.isInteger(value)) {
        return String(value);
    }
    return Number(value.toFixed(6)).toString();
}
function escapeString(value) {
    return JSON.stringify(value).slice(1, -1);
}
function upsertProjectSectionSetting(content, section, key, serializedValue) {
    const lines = content.replace(/\r/g, "").split("\n");
    const sectionHeader = `[${section}]`;
    const sectionIndex = lines.findIndex((line) => line.trim() === sectionHeader);
    if (sectionIndex === -1) {
        const trimmed = content.trimEnd();
        const suffix = trimmed ? "\n\n" : "";
        return `${trimmed}${suffix}${sectionHeader}\n${key}=${serializedValue}\n`;
    }
    let sectionEnd = lines.length;
    for (let i = sectionIndex + 1; i < lines.length; i++) {
        if (/^\[[^\]]+\]$/.test(lines[i].trim())) {
            sectionEnd = i;
            break;
        }
    }
    const keyRegex = new RegExp(`^\\s*${escapeRegex(key)}\\s*=`);
    let updated = false;
    for (let i = sectionIndex + 1; i < sectionEnd; i++) {
        if (keyRegex.test(lines[i])) {
            lines[i] = `${key}=${serializedValue}`;
            updated = true;
            break;
        }
    }
    if (!updated) {
        lines.splice(sectionEnd, 0, `${key}=${serializedValue}`);
    }
    return `${lines.join("\n").trimEnd()}\n`;
}
function readProjectSectionSetting(content, section, key) {
    const lines = content.replace(/\r/g, "").split("\n");
    const sectionHeader = `[${section}]`;
    const sectionIndex = lines.findIndex((line) => line.trim() === sectionHeader);
    if (sectionIndex === -1)
        return null;
    let sectionEnd = lines.length;
    for (let i = sectionIndex + 1; i < lines.length; i++) {
        if (/^\[[^\]]+\]$/.test(lines[i].trim())) {
            sectionEnd = i;
            break;
        }
    }
    const keyRegex = new RegExp(`^\\s*${escapeRegex(key)}\\s*=\\s*(.+)$`);
    for (let i = sectionIndex + 1; i < sectionEnd; i++) {
        const match = lines[i].match(keyRegex);
        if (!match)
            continue;
        const rawValue = match[1].trim();
        const quoted = rawValue.match(/^"([^"]*)"$/);
        return quoted ? quoted[1] : rawValue;
    }
    return null;
}
function escapeRegex(value) {
    return value.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
}
function toGdScriptValue(value) {
    if (value === null)
        return "null";
    if (typeof value === "boolean")
        return value ? "true" : "false";
    if (typeof value === "number")
        return formatNumber(value);
    if (typeof value === "string")
        return `"${escapeString(value)}"`;
    if (Array.isArray(value)) {
        return `[${value.map((entry) => toGdScriptValue(entry)).join(", ")}]`;
    }
    if (typeof value === "object") {
        const entries = Object.entries(value).map(([key, entry]) => `"${escapeString(key)}": ${toGdScriptValue(entry)}`);
        return `{${entries.join(", ")}}`;
    }
    return `"${escapeString(String(value))}"`;
}
//# sourceMappingURL=audio-tools.js.map