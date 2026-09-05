# Contributing to SyncCast

Thanks for your interest. SyncCast is at the early scaffolding stage; contributions, issues, and architecture discussions are all welcome.

## Quick start

```bash
git clone https://github.com/<your-fork>/syncast.git
cd syncast
./scripts/bootstrap.sh   # installs a silent sink (BlackHole only if needed), OwnTone, Python deps
./scripts/build.sh       # builds all Swift packages + runs tests
./scripts/dev-run.sh     # runs the menubar app + sidecar
```

Requires macOS 14+, Xcode 15+ (for `XCTest`), Homebrew, Python 3.11+.

## Repository layout

See [README.md](README.md) and [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).

## Architecture decisions

Significant architectural choices live as ADRs under `docs/adr/`. Open a PR adding a new ADR-NNN document before changing any cross-cutting design.

## Coding style

- **Swift**: follow SwiftPM defaults; 4-space indent; explicit access control on public types.
- **Python**: ruff + mypy strict (see `sidecar/pyproject.toml`).
- Keep functions small; keep transport-specific code behind the `Transport` abstraction.
- One ADR per cross-cutting design change.

## Testing

- Swift: `XCTest` cases live next to each package (`Tests/`). Run with `swift test`.
- Python: `pytest` cases under `sidecar/tests/`. Run with `pytest` from the venv.
- Integration tests with real AirPlay receivers are manual for now; we'll automate behind a "live" pytest marker in a future PR.

## No personal information in tracked files

This repository is public, and the docs here double as an engineering
notebook — which is exactly how a real device name, a home directory path or
a LAN address ends up committed by accident.

Nothing tracked in this repo (docs, ADRs, code comments, tests, fixtures,
commit messages) may contain:

- a real person's name, e-mail address or account short name;
- an absolute `/Users/<account>/…` path — write `~/…` or `/Users/<you>/…`;
- a real device name, MAC address, Bonjour `deviceid` or CoreAudio device UID;
- a private LAN or Tailscale address, or an mDNS hostname;
- pasted `launch.log` excerpts that carry device names — summarise instead;
- a city, workplace, or narration of one particular person's day.

Use neutral placeholders: "an external DisplayPort display", "an AirPlay
receiver", `~/path/to/repo`. Fixtures use documentation values — RFC 5737
addresses (`192.0.2.x`) and locally-administered MACs (`02:…`), which cannot
collide with real hardware.

`scripts/pii_scan.sh` enforces the mechanical half of this:

```bash
bash scripts/pii_scan.sh            # scan tracked files
bash scripts/pii_scan.sh --staged   # scan what you are about to commit
```

It exits non-zero on any hit and is a hard failure inside both
`scripts/package-app.sh` and `scripts/release.sh`, so a leak cannot reach a
build artefact or a GitHub release. Accepted generic mentions live in
`scripts/pii_allowlist.txt`, one `path-prefix:regex` per line — every entry
needs a written reason. Wire it in locally if you like:

```bash
printf '#!/bin/sh\nexec bash scripts/pii_scan.sh\n' > .git/hooks/pre-push
chmod +x .git/hooks/pre-push
```

(That hook is skipped if you have `core.hooksPath` pointed somewhere else —
check with `git config --get core.hooksPath` and install it there instead.)

## Pull requests

- Keep PRs small and focused. One concern per PR.
- Reference the ADR or roadmap item your change relates to.
- Update `docs/ROADMAP.md` if you advance a phase.
