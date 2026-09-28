// A deliberately hostile UI: tries to leave the terminal unusable and to type `y` at the next prompt.
//   hostile.ts control|full [iterm]
// control: only the iTerm2 profile switch and the injection, so the owner can still read the prompts.
// full:    also raw mode, conceal, colours, palette, alt screen, scroll region, mouse, bracketed paste,
//          kitty keyboard flags and an unterminated OSC, then SIGKILL before any cleanup.
// Writes `tiocsti=<rc>,errno=<n>` to fd 4.
import { dlopen, FFIType, read } from "bun:ffi";

const [mode = "full", term = ""] = process.argv.slice(2);
const darwin = process.platform === "darwin";
const out = (s: string) => process.stdout.write(s);

if (mode === "full") {
  process.stdin.setRawMode?.(true);
  out("\x1b[8m\x1b[31;41m\x1b]4;1;rgb:00/00/00\x07\x1b[?1049h\x1b[5;10r");
  out("\x1b[?1000h\x1b[?1006h\x1b[?2004h\x1b[>31u");
}
if (term === "iterm") out("\x1b]1337;SetProfile=op-remote-test\x07");

const c = dlopen(darwin ? "/usr/lib/libSystem.B.dylib" : "libc.so.6", {
  ioctl: { args: [FFIType.i32, FFIType.u64, FFIType.ptr], returns: FFIType.i32 },
  [darwin ? "__error" : "__errno_location"]: { returns: FFIType.ptr },
} as const);
const errnoFn = (c.symbols as unknown as Record<string, () => number>)[darwin ? "__error" : "__errno_location"];
const TIOCSTI = darwin ? 0x80017472n : 0x5412n;
let rc = 0;
let errno = 0;
for (const ch of "y\n") {
  rc = c.symbols.ioctl(0, TIOCSTI, new Uint8Array([ch.charCodeAt(0)]));
  if (rc !== 0) {
    errno = read.i32(errnoFn() as never, 0);
    break;
  }
}
await Bun.write(Bun.file(4), `tiocsti=${rc},errno=${errno}\n`);

if (mode === "full") {
  out("\x1b]2;op-remote-unterminated-osc");
  try {
    process.kill(process.pid, "SIGKILL");
  } catch {
    process.exit(137);
  }
}
process.exit(0);
