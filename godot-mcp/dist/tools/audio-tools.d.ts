/**
 * Audio tools for Godot MCP
 *
 * Supports AudioBusLayout resource workflows and AudioStreamPlayer scene wiring.
 */
import type { ToolHandler, ServerState } from "../index.js";
export interface AudioBus {
    name: string;
    send: string;
    volumeDb: number;
    mute: boolean;
    solo: boolean;
    bypassFx: boolean;
}
interface AudioEffectStep {
    type: string;
    properties: Record<string, unknown>;
}
export interface AudioMixOverride {
    name: string;
    volumeDb: number;
    mute?: boolean;
    solo?: boolean;
    bypassFx?: boolean;
}
declare const AUDIO_EFFECT_PRESETS: Record<string, {
    description: string;
    chain: AudioEffectStep[];
}>;
export declare function registerAudioTools(tools: Map<string, ToolHandler>, state: ServerState): void;
export declare function serializeAudioBusLayoutContent(buses: AudioBus[]): string;
export declare function parseAudioBusLayoutContent(content: string): AudioBus[];
export declare function setDefaultBusLayoutInProject(projectContent: string, layoutResPath: string): string;
export declare function getDefaultBusLayoutFromProject(projectContent: string): string | null;
/** Keep the full resource document, including unknown fields and effect resources.
 * Only bus assignments are edited/reindexed; unused subresources remain harmless.
 */
export declare function updateAudioBusLayoutContent(content: string | null, buses: AudioBus[]): string;
export declare function buildEffectChainScript(presetName: keyof typeof AUDIO_EFFECT_PRESETS, busName: string, clearExisting: boolean): string;
export declare function applyMixProfileToBuses(buses: AudioBus[], overrides: AudioMixOverride[], createMissingBuses: boolean): {
    buses: AudioBus[];
    applied: string[];
    created: string[];
};
export {};
//# sourceMappingURL=audio-tools.d.ts.map