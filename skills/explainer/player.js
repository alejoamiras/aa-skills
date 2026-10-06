// Explainer timeline runtime. Inline this file into the page; it has no dependencies.
// Contract: every scene is a pure function of time. render(t) may run for any t, in any order
// (seeking backwards included), so scenes never keep state between frames and never use
// free-running CSS animations or transitions.
//
// Explainer.mount({
//   root,                       // element holding .xp-stage, .xp-controls, .xp-captions, .xp-chapters, .xp-transcript
//   timings,                    // parsed timings.json (inline it; never fetch it — file:// blocks that)
//   audio,                      // an <audio> element, or null for captions-only
//   scenes: { [id]: (el, local, p, t) => void },  // local = seconds into the scene, p = 0..1, t = global seconds
// })
(() => {
  const clamp = (x, a = 0, b = 1) => Math.min(b, Math.max(a, x));
  const ease = (x) => (x < 0.5 ? 4 * x * x * x : 1 - (-2 * x + 2) ** 3 / 2);
  // seg(t, a, b): 0 before a, 1 after b, eased in between — the building block for every tween.
  const seg = (t, a, b) => ease(clamp((t - a) / (b - a)));
  const lerp = (a, b, k) => a + (b - a) * k;
  const reduced = matchMedia("(prefers-reduced-motion: reduce)").matches;
  const fmt = (t) => `${Math.floor(t / 60)}:${String(Math.floor(t % 60)).padStart(2, "0")}`;

  function mount({ root, timings, audio, scenes }) {
    const q = (s) => root.querySelector(s);
    const stage = q(".xp-stage");
    const play = q(".xp-play");
    const bar = q(".xp-bar");
    const clock = q(".xp-time");
    const caption = q(".xp-captions");
    const chapters = q(".xp-chapters");
    const els = Object.fromEntries([...stage.querySelectorAll("[data-scene]")].map((el) => [el.dataset.scene, el]));
    const last = timings.scenes.at(-1);
    // The media file is the authority on length; timings may end early (trailing silence) or late.
    const total = () => (audio && Number.isFinite(audio.duration) && audio.duration > 0 ? audio.duration : timings.duration);

    // Captions-only clock: wall time with explicit pause offsets, so it pauses and seeks like audio.
    let base = 0;
    let startedAt = null;
    let raf = 0;
    const now = () =>
      clamp(audio ? audio.currentTime : startedAt === null ? base : base + (performance.now() - startedAt) / 1000, 0, total());
    const playing = () => (audio ? !audio.paused && !audio.ended : startedAt !== null);
    const atEnd = () => (audio ? audio.ended : false) || now() >= total() - 0.05;

    function render() {
      const t = now();
      const scene = timings.scenes.find((s) => t < s.end) ?? last;
      const end = scene === last ? Math.max(scene.end, total()) : scene.end;
      for (const s of timings.scenes) {
        const el = els[s.id];
        if (!el) continue;
        el.hidden = s !== scene;
        if (s === scene && scenes[s.id]) {
          const local = t - s.start;
          // Reduced motion: show each scene's finished state instead of tweening into it.
          scenes[s.id](el, reduced ? end - s.start : local, reduced ? 1 : clamp(local / (end - s.start)), reduced ? end : t);
        }
      }
      caption.textContent = timings.words
        .filter((w) => w.s >= scene.start && w.s < scene.end && w.s <= t + 2.5 && w.e >= t - 2.5)
        .map((w) => w.w)
        .join(" ");
      bar.max = String(total());
      bar.value = String(t);
      clock.textContent = `${fmt(t)} / ${fmt(total())}`;
      play.textContent = playing() ? "Pause" : atEnd() ? "Replay" : "Play";
      for (const li of chapters.children) li.toggleAttribute("aria-current", li.dataset.id === scene.id);
    }

    // The single scheduling entry point, so Play→Pause→Play never leaves two frame loops running.
    function schedule() {
      cancelAnimationFrame(raf);
      raf = requestAnimationFrame(function tick() {
        render();
        if (!audio && startedAt !== null && now() >= total()) {
          base = total();
          startedAt = null;
          render();
        }
        raf = playing() ? requestAnimationFrame(tick) : 0;
      });
    }

    function seek(t) {
      t = clamp(t, 0, total());
      if (audio) audio.currentTime = t;
      else {
        base = t;
        if (startedAt !== null) startedAt = performance.now();
      }
      render();
    }

    function pause() {
      if (audio) audio.pause();
      else if (startedAt !== null) {
        base = now();
        startedAt = null;
      }
      cancelAnimationFrame(raf);
      render();
    }

    // play() must run inside the click handler: browsers refuse scripted playback without a gesture.
    play.addEventListener("click", () => {
      if (playing()) return pause();
      if (atEnd()) seek(0);
      if (audio) {
        audio.play().then(schedule, () => {
          caption.textContent = "Playback was blocked. Press Play again.";
        });
      } else {
        startedAt = performance.now();
        schedule();
      }
    });

    bar.step = "0.05";
    bar.addEventListener("input", () => seek(Number(bar.value)));
    if (audio) for (const ev of ["seeked", "pause", "ended", "loadedmetadata", "durationchange"]) audio.addEventListener(ev, render);
    // rAF stops in hidden tabs while audio keeps going; pause so picture and sound never drift apart.
    document.addEventListener("visibilitychange", () => {
      if (document.hidden && playing()) pause();
    });

    chapters.replaceChildren(
      ...timings.scenes.map((s) => {
        const li = document.createElement("li");
        li.dataset.id = s.id;
        const b = document.createElement("button");
        b.type = "button";
        b.textContent = `${fmt(s.start)} ${s.title}`;
        b.addEventListener("click", () => seek(s.start + 0.01));
        li.append(b);
        return li;
      }),
    );
    const transcript = q(".xp-transcript");
    if (transcript)
      transcript.replaceChildren(
        ...timings.scenes.map((s) => {
          const p = document.createElement("p");
          p.textContent = s.text;
          return p;
        }),
      );
    render();
    return { seek, render, pause };
  }

  // cue(timings, "pause") → global second the voice starts that word (nth occurrence), for word-synced tweens.
  const cue = (timings, word, n = 0) => {
    const norm = (w) => w.toLowerCase().replace(/[^\p{L}\p{N}]/gu, "");
    const hit = timings.words.filter((w) => norm(w.w) === norm(word))[n];
    if (!hit) throw new Error(`cue: "${word}" #${n} is not in the narration`);
    return hit.s;
  };
  window.Explainer = { mount, seg, lerp, clamp, ease, cue, reduced };
})();
