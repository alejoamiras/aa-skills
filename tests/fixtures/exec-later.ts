// Run by bun as the spawned child: waits ms, then replaces itself with file through execv, so until then the child's
// /proc exe is still bun's, as when Bun's spawn returns before the child's exec.
import { dlopen, FFIType, ptr } from "bun:ffi";

const libc = dlopen("libc.so.6", { execv: { args: [FFIType.ptr, FFIType.ptr], returns: FFIType.i32 } });
const [ms = "0", file = "", ...args] = process.argv.slice(2);
await Bun.sleep(Number(ms));
const strings = [file, ...args].map((s) => Buffer.from(`${s}\0`));
const argv = new BigUint64Array(strings.length + 1);
strings.forEach((b, i) => {
  argv[i] = BigInt(ptr(b));
});
libc.symbols.execv(ptr(strings[0]), ptr(argv));
process.exit(127);
