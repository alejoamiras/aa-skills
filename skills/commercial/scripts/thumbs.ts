// Downscales images to small JPEG data URIs (JSON map, name -> uri) so a board page can embed them.
//   bun thumbs.ts <out.json> <image> ...
const [outPath, ...inputs] = Bun.argv.slice(2);
const out: Record<string, string> = {};
for (const input of inputs) {
  const img = new Bun.Image(await Bun.file(input).bytes());
  const uri = await img.resize(900).jpeg({ quality: 78 }).dataurl();
  out[input.split("/").pop()!.replace(/\.png$/, "")] = uri;
  console.log(input, `${(uri.length / 1024).toFixed(0)} KB`);
}
await Bun.write(outPath, JSON.stringify(out));
