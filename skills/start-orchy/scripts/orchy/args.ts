// The arguments ts_run sends, NUL-separated on stdin: bun's own argv would turn a byte outside UTF-8 into U+FFFD.
export async function args(): Promise<Buffer[]> {
  return split(Buffer.from(await Bun.stdin.arrayBuffer()))[0];
}

/** At most n NUL-ended arguments, and the bytes after them: the body ts_body sends after its arguments. */
export function split(b: Buffer, n = Infinity): [Buffer[], Buffer] {
  const out: Buffer[] = [];
  let i = 0;
  for (let j = b.indexOf(0); j >= 0 && out.length < n; i = j + 1, j = b.indexOf(0, i)) out.push(b.subarray(i, j));
  return [out, b.subarray(i)];
}
