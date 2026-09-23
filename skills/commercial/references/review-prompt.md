# Foreign-reviewer pass on a cut

A reviewer from the other model family checks every cut before it goes to the owner. It works from a review pack, not from the video: `bun $C/scripts/reviewpack.ts <cut> <pack dir>` writes every frame as a JPEG and one contact sheet per second. The reviewer may not be able to run ffmpeg (`/claude` gets Read, Grep and Glob only), so the driver adds `popcrops` strips for every scan candidate and full-resolution frames for anything suspect before sending it. Run `/codex` (or `/claude` on a Codex driver) at `xhigh` on the final cut and `high` on intermediate ones. A final-cut pass over 700 frames takes about ten minutes.

It earns its keep. On one spot this pass caught:
- a scrim that differed on every render
- a bite that didn't match across shots
- VO trims clipping final consonants
- pseudo-lettering on props

It also missed a chair materialising and a crumb falling like a feather, which the owner caught on a phone. So it adds to the owner's viewing and the automated scan (`popscan.ts`); it replaces neither.

## Template

Fill every `<…>`, keep the structure, and write it to a `mktemp` prompt file.

```
I'm finishing a <duration> <tone> video ad, "<working title>", cut in ffmpeg from AI-generated clips (<models>). <One line on what changed since the last cut, including what the owner caught.> Before this goes out publicly I want a critical frame-level second opinion: check the fixes, then hunt for any slop that's left.

Premise: <two sentences: what happens and what the joke or message is>.

## Files (verified)
- Uncaptioned master: <abs path> (<W>x<H>, <fps> fps, <N> frames, <duration> s). Captioned versions sit in the same folder: <names>.
- Build script: <abs path>. Every cut point is a frame number.
- Every master frame as a 960 px JPEG, named by frame number: <pack>/frames/f000.jpg to f<N-1>.jpg.
- One-second contact sheets with frame numbers burned in: <pack>/sheets/sheet-00.png onward (sheet k holds frames <fps>k to <fps>k+<fps-1>).
- Crops of every automated pop-scan candidate: <pack>/pops.png (before / at / after, frame numbers on each row). Full-resolution frames of the suspect ranges: <pack>/full/.
- Don't modify anything. If you can't open a region you need, name the frame and the region and I'll crop it for you.

## Timeline (master frames)
<one line per shot: frames, source file and source frame range or frame map, what happens>

## Fixes to verify
<numbered: the defect, where it was, what changed, which frames to check, what "fixed" looks like>

## The hunt (the main ask)
Go through every frame: contact sheets first, then single frames and crops wherever something looks off. List anything a sharp viewer would call AI slop:
- objects that appear, vanish, duplicate or change shape
- physics: floaty or impossible motion, objects passing through hands or tables, things that don't fall or land wrong
- hands (finger count, fused fingers, grips that don't hold), faces (identity drift between shots), wardrobe changes
- background people or vehicles glitching, morphing, walking backwards
- gibberish text or signage; any brand, logo or wordmark (<the spot's branding rule>)
- anything that breaks the house rules: <paste them>
- continuity breaks across cuts that read as mistakes rather than normal ad editing (<the spot's hero props>)
- first or last frames of a shot that pop

Be critical and specific. I'd rather get false alarms than miss a real defect, but don't pad. Every item needs a frame number or range, a location in the frame, and what's wrong.

Respond in under 700 words:
- a pass/fail verdict on each fix, with the reason
- the slop list, ranked by how noticeable each item is at normal speed on a phone: must-fix / should-fix / nitpick, with frame numbers
```

## Triage

Check every finding yourself at full resolution before acting on it. Put each one on the board's round table with a call and a state:
- **Fixed**: say how, and at what cost.
- **Your call**: when a fix would cost credits, give the estimate.
- **Leave**: give the reason.

A reviewer "fail" against a stricter rule than the owner set, such as "no text at all" when the owner only asked for no brand, is a judgement for you to make and state, not an automatic fix.
