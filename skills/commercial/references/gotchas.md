# Gotchas

Every entry here produced a real defect, or nearly did, in a finished spot. Most passed one measurement and failed a second: verify fixes on every deliverable of the final render, not on one sample. Add a trap here when a new one bites.

## Video models (Seedance 2.5, Nano Banana Pro)

- **Seedance output is 24 fps HEVC with a fencepost frame**: 4 s is 97 frames and 5 s is 121. Frame 0 is the start keyframe. On the reference takes the first pair sometimes jumped, with texture and tone settling at up to 4× a typical pair's change, and sometimes didn't move at all. `popscan.ts` reports the first pair per shot, so trim frame 0 only when its crop shows a jump.
- **Objects missing from the start keyframe but present in the end keyframe materialise mid-shot.** A chair formed behind an actor over three frames, right before he sat on it. Put every object the shot needs into the start keyframe. If one forms anyway, start the shot after it has finished forming and give the frames to the neighbouring shot.
- **Falling objects drift down like feathers.** A crumb took ten frames to fall about 12 cm; gravity needs under 4 (t = √(2h/g) ≈ 0.16 s). Retime with a `select` frame map: hold, then three accelerating frames, landing on the original landing frame so the sound cue stays put.
- **Small objects duplicate or vanish near the end of a clip**, often as the camera or a prop tilts. Trim before the first duplicate.
- **Objects a hand touches can vanish.** In one shot, crumbs disappeared as they were picked up. Reshoot from start and end keyframes that show the result explicitly ("lifts one crumb; every other crumb stays exactly where it is"). Patching won't fix it.
- **Pseudo-lettering appears even when the prompt says "no lettering".** It shows up on sacks, signs and labels. On a still, blur it locally with a feathered `gblur` patch. On moving background it is usually too soft to read, so leave it.
- **Continuity across generations drifts**: a bite's contour, a jar's fill level, which side of the loaf the jar sits on. Pin hero props in the reference stills, and compare the last frame of each shot with the first frame of the next.
- **Nano Banana edits** work when the edit target comes first in `--image-references` and the prompt ends "Keep everything else identical: …". Budget three tries for a precise geometric match, at 2 credits each.
- **Process verbs fail; states hold.** "Sweeps the trail" deleted the trail and "arrives" skipped the arrival (the actor was seated from frame 0). Those two prompts caused the costly retakes. Describe one physical action between an explicit start and end keyframe.
- **Models normalise scale.** A loaf came back giant until the prompt said "about 25 cm, true-to-life scale". Repeat an odd-sized prop's scale in every prompt ("dollhouse-sized, no longer than his hand").
- **"Same framing" doesn't hold framing.** An edit cropped a head until the prompt constrained the person: "his head at exactly the same height and fully in frame".
- **Contact sheets hide motion slop.** A chair forming over three frames and a feather-slow fall both passed 12-frame sheets and two reviewers. PSNR drop rankings are swamped by freezes and flat cards: rank within live shots only (even then the chair was not the top candidate), then decide on crops.

## ffmpeg

- **`gradients` rotates over time by default.** It also silently replaces any endpoint at or past the frame edge with a random row, so every render draws a different overlay. Build static overlays from one `geq` frame, looped.
- **`afir` `dry=` is input gain, not a dry/wet mix**: `dry=0` convolves silence. The default `gtype=peak` auto-gain leaves a long IR about 50 dB down. Use `gtype=none`, mix dry and wet yourself, and set the wet gain by measurement.
- **Linear loudnorm needs headroom.** It goes linear only when the needed gain fits under the true-peak ceiling. Without a pre-drive (`volume=1.7`, then `alimiter=limit=0.8`) before the second pass, it silently fell back to dynamic mode. Read `normalization_type` in its JSON output.
- **Inline `drawtext` text breaks on `'` and `:`, and `%` starts an expansion.** Use `textfile=` with `expansion=none`.
- **`select` frame maps need `setpts=N/FPS/TB`** after them, or the kept frames keep their old timestamps. `select` only drops frames: it can't repeat or reorder them, so a hold needs `loop` or a freeze segment.
- **`zoompan` steps in whole pixels.** Push-ins jitter unless zoompan runs on a 4K upscale that is scaled back down.
- **Grain on a flat colour field turns into blocks** after the platform re-encodes it. Keep grain off solid cards.
- **Renders are not bit-reproducible.** Identical inputs differ by about 42 dB PSNR on every frame (encoder and grain noise). Audio is bit-exact. Compare renders by a PSNR threshold or by eye, never by checksum.
- **Two text passes can't share one base render in parallel.** Build the base once, then run text and audio passes per take (`--only=audio,text`).
- **Small syntax traps**: `ffprobe` takes one input per call; `scale`'s size is `96x84`, not `s=96:84`; a `drawtext` expression containing commas must be single-quoted inside the filtergraph, or the comma ends the filter.
- **Globs sweep QC files into deliverables.** Name QC frames `check-*` and keep them in `review/`.
- **Scraped measurements fail silently.** A decimal-only regex dropped integer `signalstats` rows, `-v error` hid the `psnr` summary line, and a copied path lost a segment. All three returned empty results without an error. Assert the row count of every scrape.

## Audio

- **Clipped final consonants.** A sentence-final stop ("bite", "date") is a closure, then a release burst 50–100 ms later. Silence detection calls the line over at the closure, so trimming there clips the consonant. Trim after the burst and check it in the final mix (RMS above 3 kHz).
- **Foley timing.** A sample's peak can sit 2–3 s into the file (a chair creak peaked at 3.3 s), so starting the file at the cue is always wrong. `scripts/transient.ts` reports the onset and the peak. Place the trimmed file at `cue − (event − trim-in)`, where the event is whichever of the two the ear hears as the hit. One effect per visible action.
- **Generated stings fade their last chord in about 0.25 s.** They stop dead under a held frame. Add a synthetic hall tail: decaying pink-noise IR, wet about 9 LU under the dry.
- **Digital silence under a card sounds like a broken file.** Let a tail fill it, or end on picture.
- **A music bed's composed rest can read as a dropout** before a reveal. Lift it over a short ramp.
- **Loudness target** (X, phone speakers): −16 LUFS integrated, −1.5 dBTP, two-pass linear. A 30 s spot built this way measured −15.9 LUFS, 7.1 LU range, −1.8 dBTP.

## Shell and tooling

- **zsh parses `$var[x]` inside a filtergraph string as an array subscript**, and `$var:t`, `:h`, `:r`, `:e` as path modifiers. `fontfile=$F:text=` quietly becomes the file's tail plus `ext=`. Always write `${F}`.
- **zsh doesn't word-split unquoted variables.** A flags string in `$R` goes through as one argument ("Too many positional args"). Use an array and `"${R[@]}"`.
- **Bun's `$` template has the same trap**: an interpolated flags string is one argument. Build argv arrays. A JS `.replace(str, replacement)` whose replacement contains `` $` `` or `$&` mangles the output, so use a function replacement when the text contains `$`.
- **Parallel generation jobs must append to the ledger with O_APPEND**, as `scripts/hf.ts` does. A read-modify-write loses whichever job finishes second.
- **A shared Higgsfield account shows other sessions' spend.** Run `scripts/ledger.ts` at every gate. It lists account jobs missing from the ledger, so a gap has a name instead of being a mystery. One day, the balance fell 210 credits below the ledger: three clips from another session on the same account.
- **Higgsfield login on a headless machine.** The OAuth redirect is pinned to `localhost:8765` (another `--port` fails with a redirect_uri mismatch). Run the login on the server and forward the port from the laptop with `ssh -N -L 8765:localhost:8765 <host>`. "Address already in use" there is the login's own listener, not an intruder.
- **`higgsfield account status` prints the account email, `--json` included.** Keep its output out of boards, ledgers and transcripts you share; `hf.ts` and `ledger.ts` read only `credits`.
- **`text2speech_v2` requires `--variant`** (`elevenlabs` is 0.15). Pricing without it errors.
- **`seed_audio` is priced by the prompt**, from 0.1 for three words to about 1.4 for a long one. The quote is exact, so trust `hf.ts`'s logged price over a table.
- **`seed_audio` refused an orchestral sting.** The job failed and wasn't charged; `sonilo_music --duration 4` produced it.
- **Recovering a finished job** after a runner crash: `higgsfield generate get <jobId> --json` has its `result_url`, and `hf.ts --resume <ref> <jobId>` finishes it into the ledger.
- **CLI output shapes.** `generate create --json` without `--wait` prints an array of job id strings, not job objects. `generate list --size` stops at 100 and has no paging, so older jobs can't be reconciled from the CLI. `account status --json` and `generate cost --json` give `credits` as a number: parse that, never the text, which can carry thousands separators.
- **Claude Artifacts cap each supporting file at 15 MB and each version at 64 MB**, and refuse `.m4a` (ship audio previews as `.mp3`). Board players are two-pass encodes whose bitrate comes from the spot's length (the formula is in `references/board.md`), about 13 MB each. Masters stay in the export folder.
