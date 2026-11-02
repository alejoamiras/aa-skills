import { join } from "node:path";
import { writeBytes } from "./fs";

const UPLOAD_DIR = "uploads";

// moved down two lines since the earlier run: the fingerprint holds no line
export async function saveUpload(name: string, body: Uint8Array): Promise<string> {
  const target = join(UPLOAD_DIR, name);
  await writeBytes(target, body);
  return target;
}
