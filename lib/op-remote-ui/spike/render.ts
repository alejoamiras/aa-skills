// Spike: can OpenTUI (Bun + the native dylib) start and draw one frame under the sandbox?
// Prints `render-ok` on fd 4, the channel the real UI uses for its one result line.
import { BoxRenderable, createCliRenderer, TextRenderable } from "@opentui/core";

const renderer = await createCliRenderer({
  exitOnCtrlC: false,
  useMouse: false,
  consoleMode: "disabled",
  openConsoleOnError: false,
});
const box = new BoxRenderable(renderer, { id: "box", border: true, padding: 1, title: "op-remote spike" });
box.add(new TextRenderable(renderer, { id: "msg", content: "sandbox render test: this closes by itself" }));
renderer.root.add(box);
renderer.requestRender();
await Bun.sleep(800);
renderer.destroy();
await Bun.write(Bun.file(4), "render-ok\n");
process.exit(0);
