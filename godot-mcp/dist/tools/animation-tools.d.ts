/**
 * Animation tools for Godot MCP
 *
 * Supports Animation resource (.tres/.anim) workflows and scene setup
 * for AnimationPlayer/AnimationTree nodes.
 */
import type { ToolHandler, ServerState } from "../index.js";
export interface AnimationKeyframe {
    time: number;
    value: unknown;
    transition: number;
}
export interface AnimationTrack {
    path: string;
    interpolation: "nearest" | "linear" | "cubic";
    updateMode: "continuous" | "discrete" | "capture";
    loopWrap: boolean;
    keyframes: AnimationKeyframe[];
}
export interface AnimationClip {
    length: number;
    loopMode: "none" | "linear" | "pingpong";
    step: number;
    tracks: AnimationTrack[];
}
export interface AnimationStateDefinition {
    name: string;
    animation: string;
    position?: number[];
}
export interface AnimationTransitionDefinition {
    from: string;
    to: string;
    condition?: string;
    xfadeTime?: number;
}
export interface BlendPointDefinition {
    animation: string;
    position: number[];
}
export declare function registerAnimationTools(tools: Map<string, ToolHandler>, state: ServerState): void;
export declare function buildStateMachinePlan(states: AnimationStateDefinition[], transitions: AnimationTransitionDefinition[], requestedEntryState?: string): Record<string, unknown>;
export declare function buildBlendSpacePlan(blendMode: "1d" | "2d", parameter: string, secondaryParameter: string, points: BlendPointDefinition[]): Record<string, unknown>;
export declare function serializeAnimationClipContent(clip: AnimationClip): string;
export declare function parseAnimationClipContent(content: string): AnimationClip;
//# sourceMappingURL=animation-tools.d.ts.map