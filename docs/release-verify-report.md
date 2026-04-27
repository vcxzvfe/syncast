# v0.1.0-alpha Release Verification

Verified at: 2026-04-26
Verifier: SyncCast Release Verifier Agent
Base commit: `25e592b` (origin/main)
Branch: `round11-release-verify`

## Checklist

| Check | Status | Detail |
|---|---|---|
| Release exists | PASS | `tagName=v0.1.0-alpha`, `name=v0.1.0-alpha`, `publishedAt=2026-04-27T13:57:05Z` |
| isPrerelease == true | PASS | `isPrerelease: true` |
| isDraft == false | PASS | `isDraft: false` |
| Asset count >= 1 | PASS | 1 asset: `SyncCast.app.zip` (25.07 MiB / 26,287,532 bytes) |
| Asset downloadable | PASS | Downloaded 25M to `/tmp/release-verify/SyncCast.app.zip` |
| Asset is valid zip | PASS | `Zip archive data, at least v1.0 to extract, compression method=store` |
| .app structure complete | PASS | Contains `Info.plist` (2,270 B), `MacOS/SyncCastMenuBar` (2,479,904 B), `Resources/AppIcon.icns` (612,014 B), `MacOS/SyncCastMenuBar_SyncCastMenuBar.bundle/` |
| First archive entry is `SyncCast.app/` | PASS | Top-level dir is `SyncCast.app/` |
| Tag on main branch | PASS | `v0.1.0-alpha` -> `25e592b` (ancestor of `origin/main` confirmed via `git merge-base --is-ancestor`) |
| LICENSE is MIT | PASS | `LICENSE` line 1: `MIT License`; GitHub API `license.spdx_id == "MIT"` |
| Notes <= 5 lines | PASS | 4 non-empty lines (6 total inc. blanks) |
| SHA256 digest published | PASS | `sha256:0566f92d4caebd1090f1bd1f88809dd1b385ae9125c3f1c0afcf58e97cade87a` |

## Issues found

None.

## Recommendations

- OG image manual upload still pending (per `.github/SOCIAL_PREVIEW.md`). GitHub does not expose social-preview state via REST API; verification deferred to repo owner.
- Archive contains `__MACOSX/` AppleDouble entries (macOS Finder zip artifact). Harmless and ignored on extract; cosmetic only — could be stripped via `zip -X` or `ditto -c -k --keepParent` in a future build pass if a smaller archive is desired.

## Raw outputs

### `gh release view v0.1.0-alpha --json ...`

```json
{
  "tagName": "v0.1.0-alpha",
  "name": "v0.1.0-alpha",
  "isPrerelease": true,
  "isDraft": false,
  "publishedAt": "2026-04-27T13:57:05Z",
  "assets": [
    {
      "name": "SyncCast.app.zip",
      "size": 26287532,
      "contentType": "application/zip",
      "state": "uploaded",
      "downloadCount": 0,
      "digest": "sha256:0566f92d4caebd1090f1bd1f88809dd1b385ae9125c3f1c0afcf58e97cade87a",
      "url": "https://github.com/vcxzvfe/syncast/releases/download/v0.1.0-alpha/SyncCast.app.zip"
    }
  ],
  "body": "Alpha. Self-signed, experimental, use at your own risk.\n\nTo run: unzip → drag SyncCast.app to /Applications → right-click Open (Gatekeeper).\nOr: `xattr -dr com.apple.quarantine /Applications/SyncCast.app`\n\nRequires macOS 14+ and Screen Recording permission."
}
```

### `file SyncCast.app.zip`

```
/tmp/release-verify/SyncCast.app.zip: Zip archive data, at least v1.0 to extract, compression method=store
```

### Key entries inside archive

```
        0  04-27-2026 15:53   SyncCast.app/
     2270  04-27-2026 15:53   SyncCast.app/Contents/Info.plist
  2479904  04-27-2026 15:53   SyncCast.app/Contents/MacOS/SyncCastMenuBar
        0  04-27-2026 15:53   SyncCast.app/Contents/MacOS/SyncCastMenuBar_SyncCastMenuBar.bundle/
   612014  04-27-2026 15:53   SyncCast.app/Contents/Resources/AppIcon.icns
```

### Tag location

```
$ git log v0.1.0-alpha -1 --oneline
25e592b fix(package): copy SwiftPM resource bundle + add Info.plist for codesign

$ git merge-base --is-ancestor v0.1.0-alpha origin/main && echo OK
OK
```

### Repo metadata

```json
{
  "has_issues": true,
  "has_wiki": true,
  "description": "SyncCast — open-source macOS app for synchronized audio across local + AirPlay 2 speakers (whole-house mode)",
  "license": "MIT"
}
```

### `head -3 LICENSE`

```
MIT License

Copyright (c) 2026 Zifan and SyncCast contributors
```

## Summary

**All checks passed.** Release is well-formed: prerelease flag set, signed `.app` bundle present with correct structure, MIT license, tag on `main`, low-key release notes (4 lines). No fixes applied — verify-only run as instructed.
