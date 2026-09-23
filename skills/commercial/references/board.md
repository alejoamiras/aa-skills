# The review board

The board is where the owner decides. When the driver has the Artifact tool, the board is an Artifact: private by default, and the owner shares it. Load the `artifact-design` skill before writing it, and `artifact-capabilities` for downloads. Otherwise it is `board.html` in the spot folder, with relative links to its media. Each round republishes the same file, so the link never changes.

## Pitch board

Make one board per concept, so the owner can share one without the others. Each shows:
- the premise and the turn;
- the script table (shot / seconds / action / VO / super);
- how it reads muted in 2 s;
- the expected-failure list per prop;
- the credit estimate;
- the alternate punch lines.

## Production board (from the keyframes on)

Sections in this order. The first screen answers "is it good and what do you need from me".

1. **The cut · v`N`**: the 16:9 and 1:1 players, the length, and one line on what changed.
2. **The punch**: alternate takes as players, each with its post line.
3. **Round `N` · your notes**: the reconciliation table (note / diagnosis / fix / credits / state).
4. **Open before it posts**: what only the owner can check (the timestamps to listen for) and anything unresolved.
5. **What gets posted**:
   - the post text;
   - the reply thread with each claim's permalink;
   - alt text;
   - one line per alternate.

   Each gets a copy button.
6. **The tab**: spend per phase, the cap, the balance, and any unledgered jobs.
7. **Your calls**: each pending decision, with a recommendation and its credit cost.
8. **As built**: the shot table with source frame runs, the cut list, and the loudness figures.
9. **Background** (collapsed):
   - what the spot stands for;
   - what got cut and why;
   - earlier rounds;
   - the prompts behind the shots;
   - the pitch ranking;
   - the keyframe sheet.

## Media

- **Limits.** 15 MB per supporting file and 64 MB per version. `.m4a` is refused, so ship audio as `.mp3`.
- **Masters stay out.** They live in the exports folder, and the board prints the command that fetches them.
- **Players.** Encode two-pass H.264 at 1280×720 for 16:9 and 960×960 for 1:1. Set the video bitrate from the length, so each file lands near 13 MB: kbit/s = 13 × 8000 / seconds − 128 for the audio. That is about 3,300 for 30 s and 1,600 for 60 s. Give each encode its own pass log so the two can run in parallel:

```sh
f=(-c:v libx264 -preset slow -b:v 3300k -maxrate 5000k -bufsize 7000k -passlogfile work/pass-16x9)
ffmpeg -y -i <spot>-16x9.mp4 -vf scale=1280:720 "${f[@]}" -pass 1 -an -f null /dev/null
ffmpeg -y -i <spot>-16x9.mp4 -vf scale=1280:720 "${f[@]}" -pass 2 -c:a aac -b:a 128k -movflags +faststart board/<spot>-16x9-720p.mp4
```

- **Player tags.** Use `<video controls playsinline preload="metadata" poster="…">` for the main cuts and `preload="none"` for alternates. The poster is the frame the post will open on, the premise and never the punch, so the board doesn't spoil the turn.
- **Stills and contact sheets** go in as files, or as data URIs from `scripts/thumbs.ts` when they are small.

## Downloads

Artifact viewers block `<a download>`. Declare `capabilities: {downloads: true}` and save through the capability, keeping the buttons hidden unless it resolves. Check the contract in `artifact-capabilities` before relying on this shape:

```js
const FILES = new Set(["spot-16x9-720p.mp4", "spot-1x1-960.mp4"]); // only the board's own media
(window.claude?.use?.("downloads") ?? Promise.resolve(null)).then((downloads) => {
  if (!downloads) return;
  for (const btn of document.querySelectorAll(".dl")) {
    if (!FILES.has(btn.dataset.file)) continue;
    btn.hidden = false;
    btn.onclick = async () => {
      const name = btn.dataset.file;
      try {
        const res = await fetch(name);
        if (!res.ok) throw new Error(`HTTP ${res.status}`);
        await downloads.save({ filename: name, data: await res.blob() });
        btn.textContent = "Saved";
      } catch (e) {
        btn.textContent = e?.code === "declined" ? "Download" : "Unavailable";
      }
    };
  }
});
```

The viewer confirms every save, so a decline is normal, not an error. On a standalone `board.html`, plain `<a href download>` links work.
