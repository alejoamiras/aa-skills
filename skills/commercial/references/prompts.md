# Prompt patterns

These are the patterns behind shots that made the cut. `<…>` marks a slot. `[BIBLE:x]` means "paste bible.md's descriptor for x verbatim". Reusing identical wording is how a character or prop survives six generations.

## Descriptor strings (bible.md)

Spell out what the model would otherwise invent:
- **Character**: `<hair>, <face detail>, <glasses?>, <top>, <bottom>, <one signature accessory>`. Example: "short grey beard, round steel glasses, navy fisherman's jumper, brown cords, a red wool scarf".
- **Location**: `<architecture>, <furniture with materials>, <surface>, <street/room>, <light and time of day>`.
- **Hero prop**: shape, size in centimetres, surface, and which side the distinguishing mark faces.
- **Style**: lens in mm, shot size, "photoreal", and one tone word ("deadpan commercial realism", "dry mockumentary timing").

## Stills (`nano_banana_pro --resolution 2k`; `--aspect_ratio 16:9` unless noted)

**Character reference** (`--aspect_ratio 2:3`).
> Full-body reference photo of a `<age, build>` `<man/woman>`, `[BIBLE:character]`, `<expression>`, holding `<their hero prop, if any>`. Neutral grey studio backdrop, even soft light, 50mm lens, photorealistic, tack sharp. No lettering or logos.

**Hero prop.** A studio still pins a shape the shots must keep.
> Studio product photograph of `[BIBLE:prop]`. `<The distinguishing feature, with size and position>`. The rest of it is completely intact: `<list the wrong variants: no second mark, no cuts, no loose pieces>`. Three-quarter view with `<feature>` facing the camera, seamless warm-grey backdrop, soft even light, 85mm lens, photoreal, tack sharp. No people, no hands, no lettering, no logos.

**Start keyframe.** References are passed in the order the prompt numbers them.
> Cinematic film still, same location as the first reference: `[BIBLE:location]`. `<Shot size>`, locked, eye level, `<lens>`. The `<role>` from the second reference (`[BIBLE:character]`) `<does what, at this instant>`. `<Every object the shot needs, with positions>`. `<Tone>`, photoreal. No lettering or logos.

Restate the descriptor even though the reference image is attached. The image carries the face; the words carry the wardrobe through the edit.

**End keyframe: an edit of the start.** Pass the start frame first.
> Edit the reference image; keep the location, camera angle, framing, `<both people's wardrobe>` and the light identical. `<N>` seconds later: `<the end state>`. `<What stays exactly where it is>`. Photoreal. No lettering or logos.

**Precise geometric edits.** Use relative numbers and a keep-list, and budget three tries.
> Edit the first reference image. `<The feature>` is too big. Make it about 25 percent smaller in both width and depth: `<where it stays>`, `<what grows to fill the freed area>`, matching the proportions of `<the feature>` in the second reference image. Keep everything else identical: `<list>`. Photoreal, same sharpness and grain. No lettering, labels or logos.

**Match-cut still.**
> `<The prop>` fills the frame at the same size, angle and position as the `<prop>` in the third reference, so a cut from that shot to this one reads as a match cut.

**Name the wrong readings.** When a model keeps drawing the wrong thing, list what it isn't: "It is a chip in the rim, NOT a crack, NOT a missing piece."

## Shots (`seedance_2_5 --mode omni_reference`, start and end keyframes)

> Locked `<shot size>` at `<location short name>`; the camera never moves. `<Who>` `<does the action, in order, with timing words: "for a long reluctant beat, then">`. `<Conservation clauses>`. `<Physicality clause>`. `<Light>`, `<tone>`, photoreal. No lettering or logos.

- **Conservation clauses** make vanishing and morphing less likely; they guarantee nothing, so the slop hunt still checks. Name the object and the property that must not change: "Every other `<item>` stays exactly where it is and never disappears." "Once taken, the `<mark>` keeps exactly the same shape." "Both `<props>` keep their `<feature>` facing the camera and never change shape."
- **Physicality clauses**: "natural walking with real weight, no sliding feet"; "a visible tug"; "sets it down gently".
- **Timing**: the shortest duration that fits the action. Every extra second at 1080p costs 12 credits and adds room for drift.
- Shot prompts refer to people by a short role name plus one or two identifiers ("the grey-bearded man in the navy jumper"), not the full descriptor. The keyframes and references carry identity.

## Sound

- **Foley (`seed_audio`), one action per job.**
  > `<Action described physically>`: `<the component sounds>`, close-miked, dry, no music, no voices, under one second.
- **Ambience (`seed_audio`).**
  > `<Place>` ambience: `<three or four sources>`, no music, `<N>` seconds.
- **Music bed (`sonilo_music --duration <spot length>`).**
  > `<Instruments>`, `<genre>` underscore, `<mood>`, unhurried, no melody hooks, subtle.
- **Sting (`sonilo_music --duration 4`).**
  > A short `<genre>` sting for a `<tone>` punchline: `<the exact notes>`, dry, no drums.

  A generated sting's tail can die in about 0.25 s; the build template adds a hall tail.
- **VO (`text2speech_v2 --variant elevenlabs --voice_type preset --voice_id <id>`).** The prompt is the line itself, punctuated for the read you want. Pick the voice by auditioning the hardest line in three voices.
