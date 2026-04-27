# GPT Image Generation Prompts for SyncCast Icons

A curated prompt pack for generating macOS Big Sur–style app icon candidates for **SyncCast** using ChatGPT's built-in image generation tool (DALL-E 3 / `gpt-image-1`). Eight concepts cover the five SVG candidate directions plus three bonus directions.

---

## Codex CLI probe (2026-04-26)

Probed `codex` v0.125.0 (Codex CLI, OpenAI's code agent). Result:

- **Installed**: yes (`/opt/homebrew/bin/codex`)
- **Image generation support**: **no**. Codex CLI is a code-only agent. The only image-related flag is `-i, --image <FILE>` which *attaches* images as input to a prompt — it does not generate images. Subcommands are limited to `exec`, `review`, `login`, `mcp`, `plugin`, `apply`, `cloud`, etc. No `dalle`, `gpt-image`, `image`, or `generate` subcommand exists.
- **Quota**: not consumed (no generation calls were made).
- **Recommendation**: use the **ChatGPT Plus web route** below. No CLI alternative is currently viable through Codex.

---

## How to use this pack (quick start)

1. Open <https://chatgpt.com> and sign in with a ChatGPT Plus account.
2. Select **GPT-4o** (or **GPT-5** if it appears in your model picker).
3. In the chat input, click the image-generation tool icon (the small picture/paint icon next to the attachment paperclip) — or simply prefix your message with `generate an image:`.
4. Paste one of the prompts below verbatim.
5. ChatGPT will produce **4 variants** by default (DALL-E 3 / `gpt-image-1` backend).
6. Right-click each variant → **Save image as…** → save to `docs/landing/icon-candidates/gpt-{NN}-{concept}.png` (for example `gpt-01-radial-sync-wave-a.png` through `-d.png`).
7. Iterate: tweak the **bracketed** parts of any prompt for a different feel, or ask ChatGPT in follow-up turns to "make variant 2 more saturated", "remove the inner highlight", etc.

> **Quota note**: ChatGPT Plus enforces a rolling image generation limit (~40–50 images per 3 hours). Eight prompts × 4 variants = 32 images, comfortably within one session. If you hit the limit, wait ~3 hours or split across sessions.

---

## Shared style anchor

Every prompt below shares this base styling so the candidates feel like a coherent family:

- **Format**: macOS Big Sur app icon, 1024×1024 px, rounded square (squircle) background.
- **Palette**: gradient anchored to Apple system colors — `#0A84FF` (system blue) → `#5E5CE6` (indigo) → `#BF5AF2` (purple).
- **Lighting**: subtle inner shadow on the bottom edge, soft highlight along the top edge.
- **Style**: Apple Human Interface Guidelines, modern minimalist, geometric, depth via gradient and lighting (not heavy 3D rendering).

---

## 1. Radial Sync Wave

Concentric arcs radiating from a single center point, with several small circular "output nodes" landing on the outermost arc — visualizes one source synchronized to many destinations.

**Prompt**:

```
A macOS Big Sur app icon, 1024x1024 pixels, rounded square (squircle) background with subtle inner shadow, depicting concentric thin arcs radiating outward from a single bright center point, with three to five small circular output nodes anchored along the outermost arc — visualizing one source broadcasting in perfect sync to many speakers. Apple Human Interface Guidelines style, gradient from #0A84FF (Apple system blue) to #5E5CE6 (indigo) to #BF5AF2 (purple), clean modern minimalist, depth via subtle highlight on top edge and soft inner shadow on bottom edge. Center node slightly brighter than outer nodes.
```

**Avoid**: text, letters, realistic photography, watermarks, UI chrome, menu bar elements, drop shadow under the icon, photorealistic 3D rendering, lens flare, sparkles.

**Aspect**: 1:1 square (1024×1024).

**Output**: Solid background squircle; download all 4 variants from ChatGPT.

---

## 2. Geometric Speaker Stack

Three abstract speaker shapes stacked vertically with a unifying gradient — the visual mnemonic of "stereo / multi-output stack".

**Prompt**:

```
A macOS Big Sur app icon, 1024x1024 pixels, rounded square (squircle) background with subtle inner shadow, depicting three stacked geometric speaker silhouettes (front-facing, simplified circular cone shapes) arranged vertically in slight perspective, each speaker rendered as a clean two-tone disc, the stack centered in the icon. Apple Human Interface Guidelines style, gradient from #0A84FF (Apple system blue) at top through #5E5CE6 (indigo) middle to #BF5AF2 (purple) bottom, clean modern minimalist, depth via subtle highlight on top speaker rim and soft inner shadow under the bottom speaker.
```

**Avoid**: text, letters, realistic photography, watermarks, UI chrome, menu bar elements, drop shadow under the icon, photorealistic wood-grain or fabric speaker textures, brand logos on speakers, cables.

**Aspect**: 1:1 square (1024×1024).

**Output**: Solid background squircle; download all 4 variants from ChatGPT.

---

## 3. Sync Arc with Anchored Dots

A single bold curved arc spanning the icon, with three or four equidistant dots aligned along it — clean, geometric, immediately reads as "synchronized timeline".

**Prompt**:

```
A macOS Big Sur app icon, 1024x1024 pixels, rounded square (squircle) background with subtle inner shadow, depicting a single bold curved arc sweeping diagonally across the icon from lower-left to upper-right, with four equidistant solid circular dots anchored along the arc — visualizing devices aligned to a perfectly synchronized timeline. Arc and dots in white with a soft glow; squircle background gradient from #0A84FF (Apple system blue) to #5E5CE6 (indigo) to #BF5AF2 (purple). Apple Human Interface Guidelines style, clean modern minimalist, depth via subtle highlight on top edge.
```

**Avoid**: text, letters, realistic photography, watermarks, UI chrome, menu bar elements, drop shadow under the icon, photorealistic 3D, dashed lines, arrows, more than five dots, music notes.

**Aspect**: 1:1 square (1024×1024).

**Output**: Solid background squircle; download all 4 variants from ChatGPT.

---

## 4. Monogram "S"

An abstract geometric letterform "S" — a sync curve that just happens to also be the SyncCast initial. Iconic and brandable.

**Prompt**:

```
A macOS Big Sur app icon, 1024x1024 pixels, rounded square (squircle) background with subtle inner shadow, featuring a single bold abstract geometric letterform "S" that doubles as a stylized sync curve — clean ribbon-like construction, slight depth via two-tone gradient, centered in the icon, occupying about 60% of the canvas. The S in white-to-pale-lavender gradient against a squircle background gradient from #0A84FF (Apple system blue) to #5E5CE6 (indigo) to #BF5AF2 (purple). Apple Human Interface Guidelines style, clean modern minimalist, depth via subtle highlight on top edge.
```

**Avoid**: serif fonts, decorative typefaces, text other than the single S, multiple letters, watermarks, UI chrome, drop shadow under the icon, photorealistic 3D rendering, italic styling, calligraphic flourishes.

**Aspect**: 1:1 square (1024×1024).

**Output**: Solid background squircle; download all 4 variants from ChatGPT.

---

## 5. Soft Blob Gradient

An organic, abstract blob shape with smooth gradient — Apple Music / Apple TV vibe. Less literal, more emotional.

**Prompt**:

```
A macOS Big Sur app icon, 1024x1024 pixels, rounded square (squircle) background, depicting a single soft organic blob shape (like a smooth pebble or molten droplet) centered in the icon, rendered with a smooth multi-stop gradient that shifts across its surface — evocative of Apple Music's abstract aesthetic. Blob gradient flows from #0A84FF (Apple system blue) on the upper-left, through #5E5CE6 (indigo) center, to #BF5AF2 (purple) on the lower-right. Background squircle in a darker shade of the same family (deep navy to deep indigo). Apple Human Interface Guidelines style, clean modern minimalist, depth via subtle specular highlight on the upper edge of the blob and soft ambient shadow beneath it.
```

**Avoid**: text, letters, realistic photography, watermarks, UI chrome, menu bar elements, drop shadow under the icon itself, photorealistic 3D, hard edges, geometric polygons, faces, eyes.

**Aspect**: 1:1 square (1024×1024).

**Output**: Solid background squircle; download all 4 variants from ChatGPT.

---

## 6. Audio Waveform Splitting into Branches

A horizontal waveform on the left that splits into three or four branching waveforms heading right — visualizes 1-to-many audio routing, the literal product mechanic.

**Prompt**:

```
A macOS Big Sur app icon, 1024x1024 pixels, rounded square (squircle) background with subtle inner shadow, depicting a horizontal audio waveform entering from the left side that gracefully splits and branches into three or four separate waveforms heading toward the right edge — visualizing one audio source routed to multiple synchronized outputs. Waveforms rendered as clean smooth curves (not jagged), in white with soft cyan glow. Squircle background gradient from #0A84FF (Apple system blue) at left to #5E5CE6 (indigo) center to #BF5AF2 (purple) at right. Apple Human Interface Guidelines style, clean modern minimalist, depth via subtle highlight on top edge.
```

**Avoid**: text, letters, frequency-spectrum bars, oscilloscope grid, realistic photography, watermarks, UI chrome, menu bar elements, drop shadow under the icon, photorealistic 3D rendering, music notes, headphones, microphones.

**Aspect**: 1:1 square (1024×1024).

**Output**: Solid background squircle; download all 4 variants from ChatGPT.

---

## 7. Isometric Multi-Device Illustration *(bonus)*

Three small flat-isometric devices (a Mac, a HomePod-like speaker, an AirPods-like bud) arranged on an invisible plane, connected by faint sync lines.

**Prompt**:

```
A macOS Big Sur app icon, 1024x1024 pixels, rounded square (squircle) background with subtle inner shadow, depicting three small flat-isometric devices arranged on an invisible plane: a simplified MacBook on the left, a HomePod-like cylindrical speaker in the center, and a single AirPods-like wireless earbud on the right — connected by three thin, faintly glowing sync lines that arc gracefully between them. All devices in flat geometric style with clean planar shading (no photorealism). Squircle background gradient from #0A84FF (Apple system blue) to #5E5CE6 (indigo) to #BF5AF2 (purple). Apple Human Interface Guidelines style, clean modern minimalist, depth via gentle isometric perspective and a soft highlight on the top edge of the squircle.
```

**Avoid**: text, letters, brand logos on devices, Apple logo, realistic photography, watermarks, UI chrome, menu bar elements, drop shadow under the icon, photorealistic 3D rendering, screen content showing apps, cables, people.

**Aspect**: 1:1 square (1024×1024).

**Output**: Solid background squircle; download all 4 variants from ChatGPT.

---

## 8. Pixelated Retro Speaker *(bonus)*

An 8-bit pixel-art speaker with sound waves — adds personality and stands out among gradient-heavy peers. Risky but memorable.

**Prompt**:

```
A macOS Big Sur app icon, 1024x1024 pixels, rounded square (squircle) background, depicting a single chunky 8-bit pixel-art speaker (front-facing, two-cone vertical design) centered in the icon, with three pixelated sound-wave arcs emanating to the right of the speaker. Pixel art is bold and clearly aliased (visible pixels, no anti-aliasing on the speaker itself), but the surrounding squircle background is smooth and modern. Pixel speaker in white-and-light-gray with magenta accents; squircle background smooth gradient from #0A84FF (Apple system blue) to #5E5CE6 (indigo) to #BF5AF2 (purple). Apple Human Interface Guidelines compliant outer shape, retro pixel-art interior — playful contrast between modern macOS chrome and 8-bit subject. Subtle highlight on top edge of squircle.
```

**Avoid**: text, letters, watermarks, UI chrome, menu bar elements, drop shadow under the icon, photorealistic 3D rendering, anti-aliased speaker (the pixels must be visibly chunky), realistic shading on the pixel art, smooth gradients on the speaker itself, character mascots, faces.

**Aspect**: 1:1 square (1024×1024).

**Output**: Solid background squircle; download all 4 variants from ChatGPT.

---

## End-to-end workflow

1. **Open ChatGPT Plus** (<https://chatgpt.com>) and select **GPT-4o** (or **GPT-5** if available in your account).
2. **Paste a prompt** from sections 1–8 above into the chat input. Either click the image-tool icon next to the paperclip or prefix the message with `generate an image:` to force routing to the image generator.
3. **ChatGPT auto-invokes** the built-in image generation tool (DALL-E 3 / `gpt-image-1`). You should see "Generating image…" status.
4. **Each prompt yields 4 variants**. Inspect them; if none is great, ask "regenerate with more contrast" or "tighten the composition" as a follow-up turn — ChatGPT will iterate without re-pasting the full prompt.
5. **Download winners**: right-click each chosen variant → **Save image as…** → save into `docs/landing/icon-candidates/gpt-{NN}-{concept}-{a|b|c|d}.png` (example: `gpt-01-radial-sync-wave-a.png`).
6. **Pick a winner**, then ping us to start **Phase 2** (vectorize / `.icns` bundle / Xcode asset catalog integration).
7. **Quota note**: ChatGPT Plus image generation is rate-limited to roughly **40–50 images per rolling 3-hour window**. Eight prompts × 4 variants = 32 images, which fits comfortably. If you want to explore multiple riffs per concept, split the work across two 3-hour sessions.

---

## Tips for tuning

- **Saturation / mood**: append `slightly desaturated, calm professional palette` for a more enterprise look, or `vibrant, high saturation, energetic` for a consumer feel.
- **Composition**: append `subject occupies 70% of the canvas with generous negative space` if results feel cramped.
- **Background variant**: replace the gradient line with `solid #0A84FF background` or `pure black background with subtle vignette` for alternative skins.
- **Reference style**: append `in the style of the macOS Sonoma system icons` to nudge toward Apple's house style; `in the style of Linear or Things 3` for a competing minimalist app aesthetic.
- **Negative reinforcement**: if a recurring artifact appears (e.g. ghost text, watermark, color fringing), restate the avoidance line at the *end* of the prompt — it tends to weight more heavily there.
