# GitHub Social Preview

This directory contains the social preview banner shown when the SyncCast
repo is shared on Twitter, Discord, Slack, iMessage, LinkedIn, etc.

| File | Purpose |
|------|---------|
| `og-image.png` | 1280×640 final banner — upload this to GitHub |
| `og-image-source.html` | HTML/CSS source for regeneration |

## How to upload to GitHub

GitHub social preview must be set manually — there is no API for it.

1. Open https://github.com/vcxzvfe/syncast/settings
2. Scroll to the **Social preview** section
3. Click **Edit** -> **Upload an image...**
4. Select `.github/og-image.png` from your local clone
5. Save

The image will then appear when the repo is shared on Twitter, Discord,
Slack, iMessage, LinkedIn, and other link-preview surfaces.

## Specifications

- 1280×640 PNG (2:1 aspect ratio — GitHub's recommended size)
- File size <1 MB (current build is well under 500 KB)
- Subject (icon + wordmark) visible inside the central 640×320 region,
  since some platforms crop to a square or smaller aspect

## Regenerating

The PNG was rendered from `og-image-source.html` via headless Chrome.

```bash
# From the repo root:
"/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" \
  --headless --disable-gpu --no-sandbox \
  --window-size=1280,640 \
  --hide-scrollbars \
  --screenshot=.github/og-image.png \
  "file://$(pwd)/.github/og-image-source.html"
```

After regenerating, re-upload via the GitHub Settings flow above.

### Alternative renderers

If Chrome is unavailable, any headless browser that respects
`--window-size` and `--screenshot` will work (Chromium, Brave,
Edge in headless mode). For SVG-based pipelines, port the
HTML to SVG and use `rsvg-convert -w 1280 -h 640`.

## Design notes

- **Background**: dark charcoal gradient (`#0a0d10` -> `#1c1c20`)
  matching the landing page palette
- **Icon**: `assets/branding/app-icon-1024.png` (Liquid Glass style),
  rendered at 340×340 with a subtle blue radial halo behind it
- **Wordmark**: SF Pro Display, 96px, -3px tracking
- **Accent color**: `#0A84FF` (Apple system blue) on "Local + AirPlay"
- **URL**: SF Mono, low-contrast white at 55% opacity

When updating the design, keep the icon and wordmark within the central
640×320 safe zone so it survives platform-specific cropping.
