/** Filesystem writes for tools: atomic replacement and optimistic conflict detection. */
import * as fs from "node:fs/promises";
export * from "node:fs/promises";
/** A process-wide queue also protects overlapping project roots and path aliases. */
export declare function withFileMutation<T>(operation: () => Promise<T>): Promise<T>;
export declare const readFile: typeof fs.readFile;
export declare const writeFile: typeof fs.writeFile;
//# sourceMappingURL=project-fs.d.ts.map