/**
 * TSCN (Text Scene) Parser for Godot 4.x
 *
 * Parses and serializes Godot's text-based scene format.
 * Reference: https://docs.godotengine.org/en/stable/contributing/development/file_formats/tscn.html
 */
export interface SceneHeader {
    attributes?: Record<string, string>;
    type: "gd_scene" | "gd_resource";
    loadSteps?: number;
    format: number;
    uid?: string;
}
export interface ExternalResource {
    attributes?: Record<string, string>;
    type: string;
    path: string;
    id: string;
    uid?: string;
}
export interface SubResource {
    attributes?: Record<string, string>;
    literals?: Record<string, {
        json: string;
        text: string;
    }>;
    type: string;
    id: string;
    properties: Record<string, unknown>;
}
export interface SceneNode {
    attributes?: Record<string, string>;
    literals?: Record<string, {
        json: string;
        text: string;
    }>;
    name: string;
    type?: string;
    parent?: string;
    instance?: string;
    instancePlaceholder?: string;
    owner?: string;
    index?: number;
    groups?: string[];
    properties: Record<string, unknown>;
}
export interface SignalConnection {
    attributes?: Record<string, string>;
    signal: string;
    from: string;
    to: string;
    method: string;
    flags?: number;
    binds?: unknown[];
}
export interface ParsedScene {
    extraSections?: string[];
    header: SceneHeader;
    externalResources: ExternalResource[];
    subResources: SubResource[];
    nodes: SceneNode[];
    connections: SignalConnection[];
}
export declare class TscnParser {
    /**
     * Parse a TSCN file content into structured data
     */
    static parse(content: string): ParsedScene;
    /**
     * Serialize structured scene data back to TSCN format
     */
    static serialize(scene: ParsedScene): string;
    private static parseHeader;
    private static serializeHeader;
    private static parseExtResource;
    private static serializeExtResource;
    private static parseSubResource;
    private static serializeSubResource;
    private static parseNode;
    private static serializeNode;
    private static parseConnection;
    private static serializeConnection;
    private static escapeText;
    private static extraAttributes;
    private static preservedValue;
    private static unknownAttributes;
    private static parseAttributes;
    private static parseProperty;
    static parseValue(str: string): unknown;
    private static parseArray;
    private static parseDictionary;
    static serializeValue(value: unknown, literalStrings?: boolean, autoDetect?: boolean): string;
    /**
     * Check if a string is already in Godot value format
     */
    private static isGodotValueString;
    /**
     * Add a node to a parsed scene
     */
    static addNode(scene: ParsedScene, node: Omit<SceneNode, "properties"> & {
        properties?: Record<string, unknown>;
    }): void;
    /**
     * Remove a node from a parsed scene (and its children)
     */
    static removeNode(scene: ParsedScene, nodePath: string): void;
    /**
     * Modify a node's properties
     */
    static modifyNode(scene: ParsedScene, nodePath: string, updates: Partial<SceneNode>): boolean;
    /**
     * Get the scene tree as a hierarchical structure
     */
    static getSceneTree(scene: ParsedScene): Record<string, unknown>;
    private static updateLoadSteps;
}
//# sourceMappingURL=tscn-parser.d.ts.map