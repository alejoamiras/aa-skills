// The arguments ts_run sends, NUL-separated on stdin: bun's own argv would turn a byte outside UTF-8 into U+FFFD.
export async function args(): Promise<Buffer[]> {
  const b = Buffer.from(await Bun.stdin.arrayBuffer());
  const out: Buffer[] = [];
  let i = 0;
  for (let j = b.indexOf(0); j >= 0; i = j + 1, j = b.indexOf(0, i)) out.push(b.subarray(i, j));
  return out;
}
