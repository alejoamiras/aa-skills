// Capability probes, run once outside and once inside the sandbox; check.sh compares the two.
// Each probe targets something whose unsandboxed outcome is known, so "different inside" means the
// sandbox stopped it. Imports only bun:* and node:*: nothing from node_modules can fake a result.
//   probe.ts <canary-file> <tmpdir> <home-write-path> <bun-path> <mach-names,comma,separated>
// Results go to fd 4 as `name=outcome` lines.
import { dlopen, FFIType, read } from "bun:ffi";
import { readFileSync, unlinkSync, writeFileSync } from "node:fs";
import { connect } from "node:net";

const [canary = "", tmpdir = "/tmp", homeWrite = "", bun = "", machArg = ""] = process.argv.slice(2);
const darwin = process.platform === "darwin";
const out: string[] = [];
const put = (name: string, outcome: string) => out.push(`${name}=${outcome}`);
const code = (e: unknown) => (e as { code?: string }).code ?? String(e).slice(0, 60).replace(/\s+/g, "_");

function sock(opts: { host: string; port: number } | { path: string }): Promise<string> {
  return new Promise((done) => {
    const s = connect(opts as never);
    const t = setTimeout(() => {
      s.destroy();
      done("timeout");
    }, 2000);
    s.on("connect", () => {
      clearTimeout(t);
      s.destroy();
      done("connected");
    });
    s.on("error", (e) => {
      clearTimeout(t);
      done(code(e));
    });
  });
}

function attempt(name: string, fn: () => string) {
  try {
    put(name, fn());
  } catch (e) {
    put(name, code(e));
  }
}

put("tcp", await sock({ host: "127.0.0.1", port: 1 }));
put("unix", await sock({ path: "/var/run/mDNSResponder" }));
attempt("read-canary", () => (readFileSync(canary, "utf8").startsWith("canary") ? "ok" : "wrong-content"));
attempt("write-tmp", () => {
  const p = `${tmpdir}/op-remote-probe-${process.pid}`;
  writeFileSync(p, "x");
  unlinkSync(p);
  return "ok";
});
attempt("write-home", () => {
  writeFileSync(homeWrite, "x");
  unlinkSync(homeWrite);
  return "ok";
});
attempt("spawn-true", () => {
  const r = Bun.spawnSync(["/usr/bin/true"], { env: {} });
  return `exit=${r.exitCode}`;
});
// Bun is the one binary the profile lets sandbox-exec run, so a failure here is fork denial, not exec.
// It must fail: a surviving child could inject input after the parent is reaped. (A raw ffi fork()
// is no substitute: Bun's JS runtime crashes in the forked child.)
attempt("spawn-bun", () => {
  const r = Bun.spawnSync([bun, "--version"], { env: {} });
  return `exit=${r.exitCode}`;
});

if (darwin) {
  const m = dlopen("/usr/lib/libSystem.B.dylib", {
    task_self_trap: { returns: FFIType.u32 },
    task_get_special_port: { args: [FFIType.u32, FFIType.i32, FFIType.ptr], returns: FFIType.i32 },
    bootstrap_look_up: { args: [FFIType.u32, FFIType.ptr, FFIType.ptr], returns: FFIType.i32 },
    sysctl: { args: [FFIType.ptr, FFIType.u32, FFIType.ptr, FFIType.ptr, FFIType.ptr, FFIType.u64], returns: FFIType.i32 },
    proc_pidinfo: { args: [FFIType.i32, FFIType.i32, FFIType.u64, FFIType.ptr, FFIType.i32], returns: FFIType.i32 },
    __error: { returns: FFIType.ptr },
  });
  const merr = () => read.i32(m.symbols.__error() as never, 0);
  const bp = new Uint32Array(1);
  const kr = m.symbols.task_get_special_port(m.symbols.task_self_trap(), 4 /* TASK_BOOTSTRAP_PORT */, bp);
  const names = ["com.apple.pasteboard.1", ...machArg.split(",").filter(Boolean)];
  for (const name of names) {
    attempt(`mach:${name}`, () => {
      if (kr !== 0) return `no-bootstrap-port:${kr}`;
      const port = new Uint32Array(1);
      return `kr=${m.symbols.bootstrap_look_up(bp[0] as number, Buffer.from(`${name}\0`), port)}`;
    });
  }
  attempt("procargs", () => {
    const mib = new Int32Array([1 /* CTL_KERN */, 49 /* KERN_PROCARGS2 */, process.ppid]);
    const buf = new Uint8Array(65536);
    const size = new BigUint64Array([BigInt(buf.length)]);
    return m.symbols.sysctl(mib, 3, buf, size, null, 0n) === 0 ? "ok" : `errno=${merr()}`;
  });
  attempt("pidinfo", () => {
    const buf = new Uint8Array(512);
    const n = m.symbols.proc_pidinfo(process.ppid, 3 /* PROC_PIDTBSDINFO */, 0n, buf, buf.length);
    return n > 0 ? "ok" : `errno=${merr()}`;
  });
} else {
  put("mach", "n/a");
  put("procargs", "n/a");
  put("pidinfo", "n/a");
}

await Bun.write(Bun.file(4), `${out.join("\n")}\n`);
process.exit(0);
