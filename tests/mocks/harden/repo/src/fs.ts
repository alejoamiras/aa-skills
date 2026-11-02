import { writeFile } from "node:fs/promises";

export const writeBytes = (path: string, body: Uint8Array) => writeFile(path, body);
