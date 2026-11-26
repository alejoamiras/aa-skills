# shellcheck shell=bash
# Stages a stand-in for the Gemini review leg, for the smoke and for hand checks: no real agy, key or network.
# agy_stage <dir> <repo root> makes <dir> if missing, compiles tests/fixtures/agy-stub.ts and makes, under <dir>:
#   home  the stub pinned at bin/agy, a stub key (AGY_CANARY), agy's settings file and stub.json, which picks the
#         stub's behaviour (by default one answer); every staged call runs with HOME set to it;
#   tree  the leg's scripts, lib/agy-repo.sh and the launcher, beside an engines/agy.ts that runs the repo's real run
#         with that home. The real engine takes its home from the passwd entry, never from HOME, so calling the repo's
#         own scripts with a stub HOME would still start the real agy with the real key.
# Sets AGY_HOME, AGY_RUN and AGY_RESUME; fails, with nothing set, if any step fails. The stub records each spawn as
# stub/<pid>.json in the run dir's private home, beside the message it read (<pid>.in.ndjson).
AGY_CANARY=AIzaQz1Rx2Sw3Tv4Uu5Vt6Ws7Xr8Yq9Zp0Ao1Bn2Cm3

agy_stage() {
  local dir root home tree sha
  mkdir -p -- "$1" && dir=$(cd -P -- "$1" && pwd -P) && root=$(cd -P -- "$2" && pwd -P) || return 1
  home="${dir}/home" tree="${dir}/tree/skills/gemini"
  mkdir -p -- "${home}/bin" "${home}/.agents" "${home}/.gemini/antigravity-cli" "${home}/.config/gemini" "${tree}/engines" \
    "${tree}/scripts" "${dir}/tree/lib" || return 1
  bun build --compile --outfile "${home}/bin/agy" "${root}/tests/fixtures/agy-stub.ts" > /dev/null || return 1
  sha=$(sha256sum "${home}/bin/agy" | cut -d' ' -f1) || return 1
  { printf 'path=%s\nsha256=%s\nversion=1.5.15-stub\n' "${home}/bin/agy" "${sha}" > "${home}/.agents/gemini-agy" &&
    printf '{"modelProvider":"gemini"}\n' > "${home}/.gemini/antigravity-cli/settings.json" &&
    printf 'GEMINI_API_KEY=%s\n' "${AGY_CANARY}" > "${home}/.config/gemini/.env" &&
    chmod 600 "${home}/.agents/gemini-agy" "${home}/.config/gemini/.env" &&
    printf '%s\n' '{"script":[{"answer":"stub answer"},{"result":"SUCCESS","response":"stub answer"}]}' > "${home}/stub.json"; } || return 1
  cp -- "${root}/skills/gemini/engines/agy" "${tree}/engines/agy" &&
    cp -- "${root}/skills/gemini/scripts/run-agy.sh" "${root}/skills/gemini/scripts/resume-agy.sh" \
      "${root}/skills/gemini/scripts/leg-lib.sh" "${tree}/scripts/" &&
    cp -- "${root}/lib/agy-repo.sh" "${dir}/tree/lib/" || return 1
  { printf 'const HOME = %s;\nimport { LIMITS, run } from %s;\n' "$(jq -n --arg v "${home}" '$v')" \
    "$(jq -n --arg v "${root}/skills/gemini/engines/agy.ts" '$v')" && cat << 'EOF'; } > "${tree}/engines/agy.ts" || return 1
// The repo's real run with the staged home in place of the passwd home; every other dependency is the engine's own.
import { spawn } from "node:child_process";
import { writeSync } from "node:fs";

async function stdin(max: number): Promise<Buffer> {
  const parts: Buffer[] = [];
  let size = 0;
  for await (const chunk of process.stdin) {
    parts.push(chunk);
    size += chunk.length;
    if (size > max) break;
  }
  return Buffer.concat(parts);
}

const argv = process.argv.slice(2);
if (argv[0] !== "run") process.exit(2);
const code = await run(argv.slice(1), {
  home: HOME, uid: process.getuid?.() ?? -1, now: () => Date.now(),
  timers: { set: (fn, ms) => setTimeout(fn, ms), clear: (h) => clearTimeout(h as ReturnType<typeof setTimeout>) },
  limits: LIMITS, spawn: (file, args, opts) => spawn(file, args, opts),
  signals: (stop) => {
    for (const s of ["SIGINT", "SIGHUP", "SIGTERM"] as const) process.on(s, () => stop(s));
  },
  input: () => {},
  out: (line) => {
    try {
      writeSync(1, line + "\n");
    } catch {}
  },
  env: process.env, stdin, clock: () => performance.now(),
});
process.exit(code);
EOF
  # shellcheck disable=SC2034 # read by the sourcing script
  AGY_HOME="${home}" AGY_RUN="${tree}/scripts/run-agy.sh" AGY_RESUME="${tree}/scripts/resume-agy.sh"
}
