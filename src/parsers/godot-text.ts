/** Split Godot text at newlines outside Variant expressions and quoted strings.
 * Reject incomplete expressions instead of letting a mutation discard their tail.
 */
export function splitGodotStatements(content: string): string[] {
  const statements: string[] = [];
  let current = "";
  let quoted = false;
  let escaped = false;
  let comment = false;
  const stack: string[] = [];
  const closing: Record<string, string> = { ")": "(", "]": "[", "}": "{" };
  for (const char of content.replace(/\r\n/g, "\n")) {
    if (comment) {
      if (char !== "\n") continue;
      comment = false;
    }
    if (!quoted && char === ";") { comment = true; continue; }
    if (quoted) {
      current += char;
      if (escaped) escaped = false;
      else if (char === "\\") escaped = true;
      else if (char === '"') quoted = false;
      continue;
    }
    if (char === '"') { quoted = true; current += char; continue; }
    if ("([{".includes(char)) stack.push(char);
    else if (char in closing) {
      if (stack.pop() !== closing[char]) throw new Error("Unbalanced Godot expression");
    }
    if (char === "\n" && stack.length === 0) {
      if (current.trim()) statements.push(current.trim());
      current = "";
    } else current += char;
  }
  if (quoted || stack.length) throw new Error("Incomplete Godot expression");
  if (current.trim()) statements.push(current.trim());
  return statements;
}

/** Split a Variant argument list/dictionary without splitting nested expressions. */
export function splitGodotList(value: string, separator = ","): string[] {
  const result: string[] = [];
  let depth = 0, quoted = false, escaped = false, current = "";
  for (const char of value) {
    if (quoted) { current += char; if (escaped) escaped = false; else if (char === "\\") escaped = true; else if (char === '"') quoted = false; continue; }
    if (char === '"') quoted = true;
    else if ("([{".includes(char)) depth++;
    else if (")]}".includes(char)) depth--;
    if (char === separator && !quoted && depth === 0) { result.push(current.trim()); current = ""; }
    else current += char;
  }
  if (current.trim()) result.push(current.trim());
  return result;
}
