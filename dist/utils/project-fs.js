/** Filesystem writes for tools: atomic replacement and optimistic conflict detection. */
import * as fs from "node:fs/promises";
import * as path from "node:path";
import { randomUUID } from "node:crypto";
import { AsyncLocalStorage } from "node:async_hooks";
import { fileURLToPath } from "node:url";
export * from "node:fs/promises";
const snapshots = new AsyncLocalStorage();
let mutationTail = Promise.resolve();
/** A process-wide queue also protects overlapping project roots and path aliases. */
export function withFileMutation(operation) {
    if (snapshots.getStore())
        return operation();
    const result = mutationTail.then(() => snapshots.run(new Map(), operation));
    mutationTail = result.catch(() => undefined);
    return result;
}
async function keyFor(file) {
    if (typeof file !== "string" && !Buffer.isBuffer(file) && !(file instanceof URL))
        return;
    const name = path.resolve(file instanceof URL ? fileURLToPath(file) : file.toString());
    try {
        return await fs.realpath(name);
    }
    catch (error) {
        if (error.code !== "ENOENT")
            throw error;
        // Resolve the existing parent so lexical aliases share conflict tracking.
        try {
            return path.join(await fs.realpath(path.dirname(name)), path.basename(name));
        }
        catch {
            return name;
        }
    }
}
async function contents(file) {
    try {
        return await fs.readFile(file);
    }
    catch (error) {
        if (error.code === "ENOENT")
            return null;
        throw error;
    }
}
export const readFile = (async (file, options) => {
    const store = snapshots.getStore();
    const key = store ? await keyFor(file) : undefined;
    if (!store || !key)
        return fs.readFile(file, options);
    const bytes = await contents(key);
    if (!store.has(key))
        store.set(key, bytes);
    if (bytes === null)
        return fs.readFile(file, options); // Preserve native ENOENT.
    const encoding = typeof options === "string" ? options : options?.encoding;
    return encoding ? bytes.toString(encoding) : bytes;
});
export const writeFile = (async (file, data, options) => {
    const key = await keyFor(file);
    if (!key)
        return fs.writeFile(file, data, options);
    const store = snapshots.getStore();
    const previous = store?.has(key) ? store.get(key) : await contents(key);
    const opts = typeof options === "string" ? { encoding: options } : (options ?? {});
    const flags = opts.flag ?? "w";
    if (flags !== "w" && flags !== "wx")
        throw new Error("Tool writes only support replacement or exclusive creation");
    let mode = opts.mode;
    if (mode === undefined && previous !== null)
        mode = (await fs.stat(key)).mode & 0o777;
    const temporary = path.join(path.dirname(key), `.${path.basename(key)}.${randomUUID()}.tmp`);
    try {
        await fs.writeFile(temporary, data, { ...opts, flag: "wx", mode });
        // Capture our exact bytes before publication. Reading the destination afterward
        // could adopt a concurrent editor write as this transaction's own snapshot.
        const publishedBytes = store ? await fs.readFile(temporary) : undefined;
        const current = await contents(key);
        if (previous === null ? current !== null : current === null || !previous.equals(current)) {
            throw new Error(`File changed during tool operation; retry against the latest contents: ${key}`);
        }
        if (flags === "wx") {
            // link is an atomic, no-replace publication; rename would overwrite a raced creation.
            await fs.link(temporary, key);
        }
        else {
            await fs.rename(temporary, key);
        }
        if (store)
            store.set(key, publishedBytes);
    }
    finally {
        await fs.rm(temporary, { force: true });
    }
});
//# sourceMappingURL=project-fs.js.map