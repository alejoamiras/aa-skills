---
name: commercial
description: Make a short AI video ad (about 10–60 s) with the Higgsfield CLI, the way a small 30-second spot was made end to end — Seedance 2.5 shots between Nano Banana Pro keyframes, generated VO, foley and music, and a frame-accurate ffmpeg build. The owner approves the script and a credit cap before anything is paid for, every paid job goes through a capped ledger reconciled against the account, slop is designed out at the shot list and hunted frame by frame, and the owner watches on a phone before anything posts. Trigger phrases: "make an ad", "commercial", "video ad", "30-second spot", "attack ad", "promo video", "ad with higgsfield", "/commercial". NOT for: a narrated explainer (`higgsfield-video-explainer`), a one-shot UGC or product ad from Marketing Studio (`higgsfield-generate`), product stills (`higgsfield-product-photoshoot`), thumbnails (`higgsfield-youtube-thumbnail`).
---

# Commercial

One flow for one short spot. It comes from a 30 s, 6-shot spot that cost 577 credits: shots were 87 % of the spend, 3 of the 6 were retaken, and 11 of its 20 defects were fixed in the build at no credit cost. That is one film, so treat its numbers as a starting point.

Three rules carry the flow:
1. **Decide where it's cheap.** Words are free, a still costs 2 credits, a shot 48–72, so one retake buys 24–36 stills. Fix each problem at the cheapest layer that shows it: script → stills → animatic → shots → ffmpeg.
2. **Design slop out before hunting it.** Prompts that described a process ("sweeps the trail", "arrives") caused the costly retakes; shots stated as a start and an end state didn't.
3. **Nobody sees everything.** The scans, you, the foreign reviewer and the owner's phone each caught defects the others passed, so every cut gets all four.

`$C` is this skill's directory (`~/.claude/skills/commercial`, or `~/.agents/skills/commercial` on Codex). The foreign reviewer is the other model family: `/codex` from Claude Code, `/claude` from Codex. On Codex, open frames with `view_image`. Without the Artifact tool, the board is a `board.html` in the spot folder.

## Setup

- **Workspace.** One folder outside any repo, e.g. `~/ads`, holds `expenses.jsonl`, the ledger (`touch` one to start). Commands run from there. Each spot gets a kebab-case folder: `cap` (the approved budget), `spot.md` (status line, brief, script, shot list, defects, rounds), `bible.md`, `refs/ kf/ shots/ audio/` (each file beside its `.job.json`), `review/`, `build.ts` with `work/`, and `lessons.md`.
- **Pre-flight.** `higgsfield account status --json` shows a login, enough credits and the plan; both its forms print the account email, so keep the output out of anything shared. The foreign reviewer is logged in, and `ffmpeg`, `ffprobe`, `bun` 1.4+, `curl` and a font are installed.
- **Resuming.** `spot.md` opens with a status line (`shots · s1–s4 accepted · s5 retake queued · 312 / 620 credits`). Read it, then run `ledger.ts`.

## Money

| Model | Used for | Price (the live quote wins) |
|---|---|---|
| `seedance_2_5` | shots | 1080p 12/s (48 / 60 / 72 for 4 / 5 / 6 s); 720p 7/s; 480p 3/s |
| `nano_banana_pro` | references, keyframes, edits | 2 an image, 4 at 4k |
| `text2speech_v2` | VO | 0.15 a line (`--variant elevenlabs`) |
| `seed_audio` | foley, ambience | 0.1–1.4, by prompt length |
| `sonilo_music` | bed, sting | 1.88 for 30 s, 0.25 for 4 s |

A failed job isn't charged. Seedance takes 3.5–6 min and a still about 75 s. Run long jobs in the background (on Claude Code, `run_in_background`; on Codex, a long-running command you poll), never a sleep loop.

- **Every paid job** runs as `bun $C/scripts/hf.ts <spot>/<dir> <name> <model> [flags]`. It quotes the job, refuses it without `<spot>/cap` or past the cap, records the job id before waiting, and never overwrites a take (`s<N>-t<K>`; a name is used once). Parallel calls are safe.
- **Failures.** A failed wait or download is finished with `hf.ts --resume <ref>`, never resubmitted: the job exists and is billed. An unclear submission goes to `hf.ts --release <ref>`, which checks the account before letting the reservation go.
- **The tab.** `bun $C/scripts/ledger.ts` at every gate shows spent, open and left per spot, the balance, and account jobs missing from the ledger (another session's spend on a shared account). Every message to the owner ends `Tab: <spent> + <open> of <cap> · balance <n> · unledgered: <none | list>`.
- **The budget** is the quoted shot seconds with handles, about 10 credits of stills a shot, about 20 for audio, and a retake reserve of half the shot cost. For the reference spot that was 336 × 1.5 + 60 + 20 = 584, and it came in at 577.
- **Before every paid call, check for queued owner messages.** One 72-credit shot went out a minute before "don't create the ads yet".
- **A retake names its diagnosis and what changed.** After three failed takes of one shot, stop and redesign it with the owner.

## 1 · Brief

Ask at most four questions, each with a default:
1. **Where:** platforms, organic or paid, length, aspect ratios. Default: an organic X post, 30 s, 16:9 plus a 1:1 cut, captions burned in, and a clean master.
2. **What it must do:** the audience, the one message, the response wanted.
3. **House style:** branded or not, the tone, anything never said or shown. For comparative spots the default is funny, winks only, no rival marks, and sources in the reply thread.
4. **Budget and check-ins:** the cap, and whether the owner wants to see keyframes and a rough cut or only the script and the final.

If the owner is away, carry on inside the cap as far as a review-ready cut; a script change or a cap overrun waits for them. Note the release requirements: each platform's AI-disclosure rules, the rights to every reference, voice and font, and whether a generated face resembles a real person. Read memory for the owner's standing rules, and write everything into `spot.md`.

## 2 · Claim (comparative spots)

Use one claim, asymmetric and verified at the primary source: something your side does and theirs doesn't. The film winks, and the reply thread cites each claim with a permalink. No beat claims more than its source, and there's no self-deprecation.

## 3 · Pitch

Write 3–5 concepts. Each gets a premise, the one turn, a shot count, a credit estimate and its expected failures. Keep them generable: one location, two actors, one hero prop.

Score them in one table (Lands · Reads muted in 2 s · Generable · Defensible · Credits), and have the foreign reviewer score them blind. Scores veto; the owner picks.

## 4 · Script and shot list · GATE

Write a timed script (shot, seconds, action, VO, super, sound) and a shot list (start state, end state, one action, camera, expected failures, credits). Write both against the model's habits:
- **One physical action per shot**, 4–6 s long, stated as a start and an end state. No process verbs.
- **Lock the camera** unless the move is the point ("the camera never moves").
- **Put everything the shot needs in the start state.** What appears only in the end state materialises mid-shot.
- **Avoid** counted small objects, falls and throws (or plan a retime), hands on tiny props, readable text, busy backgrounds, animals and fast head turns.
- **For each hero prop, write what the model will get wrong** (rescaling it, merging two, passing it through a hand), and repeat a qualifier in every prompt ("dollhouse-sized, no longer than his hand").
- **Keep about 0.5 s of slack at each end of a shot.** If a 1:1 cut is due, keep the action inside the centre square.
- **Choose the first frame on purpose:** autoplay opens on it. It sets up the premise and never shows the turn.
- **Text and branding come from the build,** never from the model.

The foreign reviewer checks the script at `high`. **Gate:** the owner approves the script, the shot list and the budget. Write the cap to `<spot>/cap` and quote the approval in `spot.md`. Nothing is paid for before this.

## 5 · Bible, keyframes, animatic

- **`bible.md`** holds one descriptor string each for the characters, the location, the hero props and the style. Paste them verbatim into every still prompt, and put scale words in every prompt ("about 25 cm, true-to-life scale"). The patterns are in `references/prompts.md`.
- **References:** a full-body still of each character on grey, the empty location, and a studio still of each hero prop.
- **Keyframes.** Make `kf/s<N>-start.png` from the references, and put everything the shot needs in it: anything that appears only in the end state materialises mid-shot. The end state goes in the shot prompt, never in an end image (see Shots). Compare shot N's end state with shot N+1's start, and check hands, lettering and scale at full resolution.
- **Animatic.** Record scratch VO (0.15 a line), then run `bun $C/scripts/animatic.ts <spot>/review/animatic.mp4 <spot>/kf/s1-start.png@4.25 … --audio <spot>/audio/vo1.mp3@0.4 …`. Watch it muted, then with sound. It is the last free place to change timing.

## 6 · Shots

```sh
bun $C/scripts/hf.ts <spot>/shots s3-t1 seedance_2_5 --mode omni_reference \
  --start-image <spot>/kf/s3-start.png \
  --image-references <spot>/refs/<character>.png \
  --duration 5 --resolution 1080p --aspect_ratio 16:9 --generate_audio false \
  --prompt "<camera. ordered action. conservation. physicality. tone.> No lettering or logos."
```

- **Start image only.** A take given an end image, even one identical to its start, came back re-lit and repainted from frame 0. Name the keyframe's own shot size and say "exactly the framing of the first frame; keep the light exactly as in the first frame": a different shot size in the prompt reframes the shot.
- **Pilot the riskiest shot on its own.** Launch the rest together once it has survived the slop hunt.
- **Generated audio stays off.** The build places every sound on a measured frame.
- **Output** is 24 fps, and a 5 s take is 121 frames. Frame 0 is the start keyframe.

## 7 · Slop hunt (every take, before it enters the cut)

1. **Contact sheet:** `$C/scripts/sheet.sh <take>` shows staging, framing and continuity. Sheets don't show motion slop.
2. **Pop scan:** `bun $C/scripts/popscan.ts <take> "" | bun $C/scripts/popcrops.ts <take> <spot>/review/<name>-pops.png`. Look at every row, including any first or last frame pair it flags. The scan ranks candidates; the crops decide.
3. **First and last frames** of the range you'll use: look for anything that appeared, vanished or changed shape.
4. **Falls:** anything falling takes √(2h/g) s, so a 12 cm drop takes under 4 frames at 24 fps.
5. **Hands and faces** at full resolution, on every grip and head turn.

| Defect | Cheapest fix |
|---|---|
| The first frame jumps | start at source frame 1–2 |
| An object materialises | start after it has formed and give the frames to the neighbouring shot; failing that, add it to the start keyframe and retake |
| A feather-slow fall | a frame map: hold, then 3 accelerating frames that land on the original landing frame |
| Duplicates near the end | trim before the first one |
| A touched object vanishes | retake with a prompt that states the result, with a conservation clause |
| A skipped beat (the end state from frame 0) | a new start keyframe, one action |
| A still between live shots reads as a photograph | animate it from the still with one small action |
| Pseudo-lettering | blur it on the still; leave soft background text |

Try fixes cheapest first: trim, retime, hold, pixel patch, still edit, retake. Log each in `lessons.md`. Every trap so far is in `references/gotchas.md`.

## 8 · Sound

- **VO.** Audition three voices (`higgsfield voices list --json`) on the real punch line, and record 2–3 takes of it. The chosen take's words become the caption, verbatim. Trim after the final consonant's release burst, not at the silence before it.
- **Foley.** Run one `seed_audio --format wav` job per visible action. `bun $C/scripts/transient.ts <file>` reports the onset and the peak, which can sit frames apart. Place the file at `cue − (event − trim-in)`, and confirm it by ear.
- **Bed and sting.** Generate an ambience per location, a bed with `sonilo_music --duration <length>` and a sting with `--duration 4`. A generated sting dies in about 0.25 s; the template adds a hall tail.

## 9 · Build

Copy `$C/templates/build.ts` into the spot folder and replace every `TODO`. The edit is a named timeline of `shot`, `still` and `freeze` segments, and every cue is `cue("<segment>", <seconds into it>)`. The build refuses anything silently wrong: a repeated segment id, frame runs that go backwards or past the source, a moved cut list, a cue off the timeline, a loudnorm that went dynamic, a render with the wrong frame count.

Render alternate punch lines one at a time with `bun <spot>/build.ts --take=<name> --only=audio,text`. The mix values are the reference spot's, so re-measure them.

## 10 · QC and review

- **Machine checks.** `bun $C/scripts/qc.ts --frames <N> --cues <K> <spot>/<spot>-16x9.mp4 <spot>/<spot>-16x9-clean.mp4 <spot>/<spot>-1x1.mp4 <spot>/<spot>.srt` must pass: the decoded frame count, −16 ± 0.5 LUFS and a true peak of −1 dBTP or lower on the final AAC, and a clean SRT.
- **By eye.** The captions match the VO word for word and are at least 52 px on the 1920×1080 frame (44 px was too small on a phone). The 1:1 cut keeps the action in frame. `popscan.ts` has run on the master with the cut list (`CUTS` from `build.ts`, as is).
- **Foreign review.** Pack the cut with `bun $C/scripts/reviewpack.ts <master> <spot>/review/pack-v<N>`, add crops and full-resolution frames of every candidate, and send it with `references/review-prompt.md`, at `high` on a rough cut and `xhigh` on the final. Put the house rules in the prompt, and reproduce a finding on the exact file before rejecting it. Stop when a pass returns no must-fix, after three at most. Its audio remarks are guesses from numbers.
- **The owner's phone watch** is the last gate. Name what nobody else could check, with timestamps: "the crunch at 0:14.5, the jump into the sting, the last consonant".

## 11 · Deliver and rounds

- **Export.** `bun $C/scripts/export.ts <exports> <spot> <N> <files…>` publishes a versioned set that never overwrites anything, with `SHASUMS256.txt`. Give the owner the command that fetches it.
- **The board**, per `references/board.md`: the cuts, what gets posted with copy buttons, the tab, and the owner's open calls.
- **Post copy stays off the video.** The post winks, the reply thread cites, each alternate gets its own post line, and there's alt text.
- **Owner notes** go into a table in `spot.md` and on the board: note, diagnosis, fix, credits, state. Fix, rerun section 10 in full (renders don't reproduce bit for bit), and export `v<N+1>`. Anything past the cap needs a new approval.

## 12 · Close

Add new traps to `references/gotchas.md` in generic words. This skill lives in a public repo: no campaign, brand or rival names, and no local paths. Save the owner's new standing rules to memory, and put the final tab in `spot.md`.

## Hard rules

- No paid job before the script gate and a written cap, none past the cap, and none while an owner message is unread.
- Every paid job goes through `hf.ts`. An interrupted wait or download is resumed, never resubmitted; a job that failed cost nothing and is retried as a new take. No take or delivered file is overwritten.
- Every image and shot prompt ends "No lettering or logos." Words on screen come from the build.
- Nothing posts before `qc.ts` passes and the owner has watched and listened on a phone and approved the files.
- Comparative claims are sourced in the thread, and no rival mark appears on screen without the owner's say-so.
