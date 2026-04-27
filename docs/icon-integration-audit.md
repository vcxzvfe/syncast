# SyncCast Icon Integration Audit

> Read-only scan of the repo at base `3350280` to map every place an icon/logo
> currently lives or is conspicuously missing. Phase 2 builders should treat
> this as the single source of truth for "where do I plug the new asset in?".
>
> **Scope:** macOS app icon (`.icns` / `Assets.xcassets`), menubar tray icon
> (`MenuBarExtra` / `NSStatusItem`), landing-page favicon and OG meta, GitHub
> social-preview image, and existing logo SVGs.

---

## Summary

| Use case | Current state | Phase 2 must edit | Phase 2 must add | Notes |
|---|---|---|---|---|
| **macOS App Icon** (Finder, Dock peek, About box) | Not present. No `.icns`, no `Assets.xcassets`, no `AppIcon.appiconset`. `Info.plist` has no `CFBundleIconFile` / `CFBundleIcons` key. | `apps/menubar/Resources/Info.plist` (add `CFBundleIconFile`) — `scripts/package-app.sh:47-56` (add a `cp …icns Resources/` step in stage 2) | `apps/menubar/Resources/AppIcon.icns` (or an `Assets.xcassets/AppIcon.appiconset/` if we move to xcasset compilation) | `LSUIElement = true` means no Dock tile, but Finder, Spotlight, About, drag-drop, and the dialogs still need an icon. |
| **Menubar Tray Icon** (the thing in the system menubar) | SF Symbol, dynamic per state. `Image(systemName: model.statusIconName)` — `apps/menubar/Sources/SyncCastMenuBar/SyncCastApp.swift:66`. State→symbol map in `AppModel.swift:351-359`: `speaker.wave.2` / `.bubble` / `.fill` / `speaker.slash`. | `apps/menubar/Sources/SyncCastMenuBar/SyncCastApp.swift:62-68` (`label:` block of `MenuBarExtra`) — swap `Image(systemName:)` for a custom `Image("MenubarIcon")` (template) **or** keep state-driven SF Symbols and only override "running"/"idle". `AppModel.swift:351-359` may need a string→asset map. | `apps/menubar/Resources/Assets.xcassets/MenubarIcon.imageset/` (16/32/64 px, set "Render As: Template Image") **and** SwiftPM resource declaration in `apps/menubar/Package.swift:11-19` (`resources: [.process("Resources/Assets.xcassets")]`). | Currently SwiftUI's `MenuBarExtra` is used (not legacy `NSStatusItem`/`NSStatusBar`). Custom images **must** be 1× ≤ 18 pt tall and template-rendered to invert correctly under dark menubar; SF Symbols already are. The `statusIconName` switch is a four-state animation hint — Phase 2 should preserve state feedback even if it changes the base art. |
| **Landing-page favicon** | Not present. `docs/landing/index.html:3-219` has `<head>` with charset, viewport, description, title, inline `<style>` — but **zero** `<link rel="icon">` / `apple-touch-icon` / `manifest`. | `docs/landing/index.html` — insert favicon `<link>` tags inside `<head>` after the `<title>` on line 7 (before line 8's `<style>`). | `docs/landing/favicon.ico`, `docs/landing/favicon-32.png`, `docs/landing/favicon-180.png` (apple-touch), optional `docs/landing/favicon.svg` (modern browsers prefer SVG). | The brand mark inline-SVG in nav (`index.html:226-230`) is a generic "audio-wave path", **not** the SyncCast logo — it should be swapped to reference `logo.svg` once the canonical mark is final. |
| **GitHub OG / social preview** | Not present in repo. `.github/` only contains `workflows/ci.yml`. No `.github/og-image.png`, no `og:image` / `twitter:card` meta in `docs/landing/index.html`. README has no top-of-file banner image — only shields.io badges. | `docs/landing/index.html` — add `<meta property="og:image" …>` + `<meta name="twitter:card" content="summary_large_image">` block in `<head>`. README.md and README.zh-CN.md — optional banner `<img>` above shields. | `docs/og-image.png` (1200×630) **or** `.github/og-image.png` if we want GitHub's repo-level social preview. (GitHub's social-preview image is configured in repo Settings → Social Preview, but committing the source PNG into `.github/` is the convention.) | GitHub repo social-preview is **uploaded via Settings UI**, not auto-picked from a path. The committed PNG is just for source-tracking. |
| **Existing source assets** | `docs/landing/logo.svg` (64×64 master mark, blue→purple gradient, "sync waves + 3 receivers + center source"). `docs/landing/logo-horizontal.svg` (256×64 wordmark variant). Currently **referenced nowhere** — not loaded by `index.html`, not bundled into `.app`. Repo contains **no** `.png`, `.icns`, `.ico` files at all. | n/a (assets exist but unreferenced). | n/a. | These two SVGs are the canonical brand source; Phase 2 raster pipeline should rasterize from `logo.svg` for app icon + favicon, and from `logo-horizontal.svg` for OG / README banner. |

---

## Detail

### 1. macOS App Icon

**Current state.** Nothing. The `.app` produced by `scripts/package-app.sh` has no
icon at all — Finder will show the generic "blank application" tile.

Evidence:

- `find . -name 'AppIcon.appiconset'` → 0 results.
- `find . -name 'Assets.xcassets'` → 0 results.
- `find . -name '*.icns'` → 0 results.
- `apps/menubar/Resources/Info.plist` — no `CFBundleIconFile`, no `CFBundleIconName`, no `CFBundleIcons` key (verified line-by-line, lines 1-46).
- `scripts/package-app.sh:47-56` (stage "2) bundle skeleton") copies `Info.plist` to `Contents/Info.plist` but never copies any icon resource into `Contents/Resources/`.

**Apple's required sizes for a non-xcasset `.icns`** (per `iconutil` and HIG):
16, 32, 64 (= 32@2x), 128, 256, 512, 1024 (= 512@2x) — usually paired as
`@1x` + `@2x` so source PNGs are: 16, 32, 64, 128, 256, 512, 1024 (7 PNGs)
arranged in an `iconset/` folder, then `iconutil -c icns AppIcon.iconset`.

**Phase 2 step-by-step.**

1. Generate seven PNGs from `docs/landing/logo.svg` at sizes
   `{16, 32, 64, 128, 256, 512, 1024}`. Keep transparent background; HIG says
   the icon itself should be inset within a rounded-square frame for macOS 11+.
2. Create `apps/menubar/Resources/AppIcon.iconset/` with
   `icon_16x16.png`, `icon_16x16@2x.png` (=32), `icon_32x32.png`,
   `icon_32x32@2x.png` (=64), `icon_128x128.png`, `icon_128x128@2x.png`
   (=256), `icon_256x256.png`, `icon_256x256@2x.png` (=512),
   `icon_512x512.png`, `icon_512x512@2x.png` (=1024).
3. Run `iconutil -c icns apps/menubar/Resources/AppIcon.iconset` →
   produces `apps/menubar/Resources/AppIcon.icns`.
4. Edit `apps/menubar/Resources/Info.plist` — add **before** the closing `</dict>` (line 45):

   ```xml
   <key>CFBundleIconFile</key>
   <string>AppIcon</string>
   ```
5. Edit `scripts/package-app.sh` after line 53 (`cp …Info.plist…`):

   ```bash
   cp "$REPO_ROOT/apps/menubar/Resources/AppIcon.icns" "$RES_DIR/AppIcon.icns"
   ```
6. Re-run `scripts/package-app.sh` — verify `dist/SyncCast.app/Contents/Resources/AppIcon.icns` is present and Finder shows the icon.

**Optional alternative:** use `Assets.xcassets/AppIcon.appiconset` and let SwiftPM compile it via `actool`. SwiftPM 5.9 supports `.process("Assets.xcassets")` in `Package.swift` resources. This requires changing `apps/menubar/Package.swift:11-19` to declare resources, and stripping the `cp Info.plist` plumbing if we let SwiftPM emit `Info.plist` too. **Verdict for Phase 2:** stay with the explicit `.icns` route — it's one fewer moving part and matches the "no Xcode" build philosophy of `package-app.sh`.

---

### 2. Menubar Tray Icon

**Current state.** SwiftUI `MenuBarExtra` (not legacy `NSStatusItem`), label is an SF Symbol that animates with streaming state.

**Files & lines:**

- `apps/menubar/Sources/SyncCastMenuBar/SyncCastApp.swift:57-70`:

  ```swift
  var body: some Scene {
      MenuBarExtra {
          MainPopover()
              .environment(model)
              .frame(width: 340)
      } label: {
          Label {
              Text("SyncCast")
          } icon: {
              Image(systemName: model.statusIconName)
          }
      }
      .menuBarExtraStyle(.window)
  }
  ```
- `apps/menubar/Sources/SyncCastMenuBar/AppModel.swift:351-359`:

  ```swift
  var statusIconName: String {
      switch streamingState {
      case .idle:     return "speaker.wave.2"
      case .starting: return "speaker.wave.2.bubble"
      case .running:  return "speaker.wave.3.fill"
      case .stopping: return "speaker.wave.2.bubble"
      case .error:    return "speaker.slash"
      }
  }
  ```

**Template behavior.** SF Symbols loaded via `Image(systemName:)` are
automatically template images — they invert correctly under dark/light
menubar. No explicit `isTemplate = true` is needed. **If Phase 2 swaps in a
custom `Image("MenubarIcon")`, the imageset must be marked "Template" in the
xcasset's `Contents.json` (`"template-rendering-intent": "template"`)** or the
icon will render as solid black under a dark menubar.

**Sizing.** macOS menubar height is 22 pt (~16-18 pt safe area for the icon).
For a custom imageset provide 1×/2×/3× at 16-pt design size (so 16×16, 32×32,
48×48 px). Keep the artwork monochrome — color is dropped under template
rendering.

**Phase 2 options.**

- **Option A — keep SF Symbols, add only "branded" stop/idle states.** Lowest
  risk. Edit `AppModel.swift:351-359` so only `.idle` and `.running` resolve
  to a custom asset name; the bubble / slash variants stay as SF Symbols.
  Then `SyncCastApp.swift:66` becomes:

  ```swift
  } icon: {
      if let asset = model.statusIconAsset {
          Image(asset)            // custom branded mark
      } else {
          Image(systemName: model.statusIconName) // SF Symbol fallback
      }
  }
  ```

- **Option B — fully custom, four states.** Drop SF Symbols entirely; ship
  four imagesets (`MenubarIdle`, `MenubarStarting`, `MenubarRunning`,
  `MenubarError`). Replace `statusIconName` return values with asset names and
  always use `Image(_:)`. More art work, more consistent brand.

**Either option requires:** declaring resources in `apps/menubar/Package.swift` lines 11-19, e.g.:

```swift
.executableTarget(
    name: "SyncCastMenuBar",
    dependencies: [...],
    path: "Sources/SyncCastMenuBar",
    resources: [.process("../../Resources/Assets.xcassets")]
)
```

…or, simpler, move the xcasset under `Sources/SyncCastMenuBar/Resources/` so
SwiftPM picks it up by default.

---

### 3. Landing-page Favicon

**Current state of `docs/landing/index.html` `<head>`** (lines 1-219, verified):

```html
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<meta name="description" content="SyncCast — open-source macOS menubar app …">
<title>SyncCast — One audio source. Every speaker in the house.</title>
<style>
  /* …inline CSS… */
</style>
</head>
```

No `<link rel="icon">`, no `apple-touch-icon`, no `manifest.webmanifest`.

**Phase 2 step-by-step.**

1. Rasterize `docs/landing/logo.svg` to:
   - `docs/landing/favicon.ico` (multi-resolution: 16, 32, 48 — `convert` / `magick` / `png2ico` will do it).
   - `docs/landing/favicon-16.png`, `favicon-32.png`, `favicon-180.png` (apple-touch-icon).
   - Optional `docs/landing/icon-512.png` for PWA-style browsers.
2. Edit `docs/landing/index.html` — insert directly after the existing `<title>` (line 7), before `<style>` (line 8):

   ```html
   <link rel="icon" href="favicon.ico" sizes="any">
   <link rel="icon" href="logo.svg" type="image/svg+xml">
   <link rel="apple-touch-icon" href="favicon-180.png">
   ```
3. (Optional) Update the inline SVG in the nav-brand `<span class="mark">` (`index.html:226-230`) to reference `logo.svg` directly instead of duplicating an audio-wave path:

   ```html
   <span class="mark" aria-hidden="true">
     <img src="logo.svg" alt="" width="28" height="28">
   </span>
   ```

   The current CSS at `index.html:55-63` paints a gradient pill behind the
   inline SVG; if you swap to `<img>`, also delete the `background:
   linear-gradient(…)` line in `.brand .mark` so the logo isn't double-painted.

---

### 4. GitHub OG / Social Preview

**Current state.**

- `.github/` contains only `workflows/ci.yml` — no `og-image.png`, no `social-preview.png`.
- `docs/landing/index.html` — no `og:` or `twitter:` meta tags. (Verified: `grep -n 'twitter:\|og:'` → 0 matches.)
- `README.md` and `README.zh-CN.md` — no top-of-file banner `<img>`. Only shields.io badges (license, macOS-14+, Swift-5.9+).

**Phase 2 step-by-step.**

1. Compose a 1200×630 PNG using `docs/landing/logo-horizontal.svg` + tagline ("One audio source. Every speaker in the house.") on the brand gradient (`#0A84FF → #5E5CE6`).
2. Save as `docs/og-image.png` (or `.github/og-image.png` — the latter is conventional but functionally identical; pick one and stay consistent).
3. Edit `docs/landing/index.html` — add to `<head>` (after `<meta name="description">` line 6):

   ```html
   <meta property="og:type" content="website">
   <meta property="og:title" content="SyncCast — One audio source. Every speaker in the house.">
   <meta property="og:description" content="Open-source macOS menubar app that captures system audio with ScreenCaptureKit and routes it in sync to local speakers and AirPlay 2 receivers.">
   <meta property="og:image" content="https://syncast.io/og-image.png">  <!-- or wherever it's hosted -->
   <meta property="og:url" content="https://syncast.io">
   <meta name="twitter:card" content="summary_large_image">
   <meta name="twitter:image" content="https://syncast.io/og-image.png">
   ```
4. (Optional) Add a banner `<img>` to the top of `README.md` above the shields, e.g. `![SyncCast](docs/og-image.png)`.
5. Configure repo-level **Social Preview** at GitHub Settings → "Social preview" → upload the PNG. (This is a UI step, not a commit step.)

---

### 5. Available Source Assets

**`docs/landing/logo.svg`** (64×64, 894 bytes):

- Uses `linearGradient #0A84FF → #5E5CE6` (id `sc-grad`).
- Composition: two concentric arcs (sync waves), three peripheral 4-radius circles (one top, two flanking — "receivers"), one central 5-radius solid `#0A84FF` circle ("source").
- Pure stroke + fill, no text, no embedded raster — rasterizes cleanly at any size.

**`docs/landing/logo-horizontal.svg`** (256×64, 1101 bytes):

- Same gradient (id `sch-grad`), icon scaled to 32×32 in left half, wordmark "SyncCast" rendered in `-apple-system, system-ui, sans-serif`, weight 600, letter-spacing -0.5, color `#0A84FF`.
- Caveat: the `font-family` is system-dependent — when rasterized on a non-Apple machine the wordmark may shift. For high-fidelity OG images and any baked PNG, **convert text-to-paths first** (`inkscape --export-text-to-path` or `svgo --convert-text-to-path`) before rasterizing.

**Nothing else exists.** No PNGs, no ICOs, no ICNS, no candidate folder. The
`docs/landing/icon-candidates/` path mentioned in the task brief does not
exist at this commit.

---

## Phase 2 Builder Cheat-Sheet

For each Phase 2 sub-agent, here is the minimum-viable change list. Numbers are file:line at base `3350280`.

### A. App-icon agent (Finder/Dock/About)

| Step | Where | Action |
|---|---|---|
| 1 | n/a | Rasterize `docs/landing/logo.svg` → 7 PNGs (16, 32, 64, 128, 256, 512, 1024). |
| 2 | `apps/menubar/Resources/AppIcon.iconset/` | Create with the 10 macOS-named PNGs (1× + 2× pairs). |
| 3 | n/a | Run `iconutil -c icns` → `apps/menubar/Resources/AppIcon.icns`. |
| 4 | `apps/menubar/Resources/Info.plist` (before `</dict>` line 45) | Add `CFBundleIconFile = AppIcon`. |
| 5 | `scripts/package-app.sh` (after line 53) | Add `cp "$REPO_ROOT/apps/menubar/Resources/AppIcon.icns" "$RES_DIR/AppIcon.icns"`. |
| 6 | n/a | Re-run `scripts/package-app.sh`, verify Finder icon. |

### B. Menubar-tray agent

| Step | Where | Action |
|---|---|---|
| 1 | `apps/menubar/Resources/Assets.xcassets/MenubarIcon.imageset/` | Create imageset (1×/2×/3× PNGs at 16-pt design), `template-rendering-intent: "template"` in `Contents.json`. |
| 2 | `apps/menubar/Package.swift:11-19` (or move xcasset to `Sources/SyncCastMenuBar/Resources/`) | Declare `resources: [.process("Resources/Assets.xcassets")]`. |
| 3 | `apps/menubar/Sources/SyncCastMenuBar/SyncCastApp.swift:66` | Swap `Image(systemName: model.statusIconName)` for `Image("MenubarIcon")` (or hybrid: keep state-driven SF Symbols and override only specific states). |
| 4 | `apps/menubar/Sources/SyncCastMenuBar/AppModel.swift:351-359` | If going hybrid, add a parallel `statusIconAsset: String?` computed property. |

### C. Favicon agent

| Step | Where | Action |
|---|---|---|
| 1 | `docs/landing/favicon.ico`, `favicon-32.png`, `favicon-180.png` | Rasterize from `logo.svg`. |
| 2 | `docs/landing/index.html` (after line 7, before line 8 `<style>`) | Insert 3 `<link>` tags. |
| 3 | `docs/landing/index.html:226-230` (optional) | Replace inline SVG brand-mark with `<img src="logo.svg">`; remove `background: linear-gradient(…)` from `.brand .mark` CSS at line 58-60. |

### D. OG / social-preview agent

| Step | Where | Action |
|---|---|---|
| 1 | `docs/og-image.png` (or `.github/og-image.png`) | Rasterize 1200×630 from `logo-horizontal.svg` + tagline on brand gradient. |
| 2 | `docs/landing/index.html` `<head>` (after line 6) | Insert 6 `og:` / `twitter:` meta tags. |
| 3 | `README.md` line 1 (optional) | Add banner `<img>` above shields-row. |
| 4 | n/a — manual UI step | Upload PNG via GitHub Settings → Social Preview. |

---

## What this audit deliberately does NOT cover

- **Notarization-ready icon polish.** macOS Sequoia/Tahoe further inset and shadow icons differently — once Phase 2 has the raw 1024×1024 master, validate with `Icon Composer` or screenshot at every size.
- **In-app branded splash / About-box image.** Not present in repo today; would be a future Phase 3.
- **Dynamic dark/light variants for the menubar icon.** Template rendering covers it for free; only revisit if Phase 2 wants a non-template colored icon (rare).
- **Linux/Windows variants.** SyncCast is macOS-only (`Info.plist:21 LSMinimumSystemVersion = 14.0`), so we explicitly skip `.png` favicons for Windows tile / Microsoft `browserconfig.xml`.

---

*Generated by Round 11 icon-audit agent. Base commit `3350280`.*
