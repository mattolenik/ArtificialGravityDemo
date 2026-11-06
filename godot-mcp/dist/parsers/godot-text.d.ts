/** Split Godot text at newlines outside Variant expressions and quoted strings.
 * Reject incomplete expressions instead of letting a mutation discard their tail.
 */
export declare function splitGodotStatements(content: string): string[];
/** Split a Variant argument list/dictionary without splitting nested expressions. */
export declare function splitGodotList(value: string, separator?: string): string[];
//# sourceMappingURL=godot-text.d.ts.map