# Contributing to SyncCast

Thanks for your interest. SyncCast is at the early scaffolding stage; contributions, issues, and architecture discussions are all welcome.

## Quick start

```bash
git clone https://github.com/<your-fork>/syncast.git
cd syncast
./scripts/bootstrap.sh   # installs BlackHole, OwnTone, Python deps
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

## Pull requests

- Keep PRs small and focused. One concern per PR.
- Reference the ADR or roadmap item your change relates to.
- Update `docs/ROADMAP.md` if you advance a phase.
