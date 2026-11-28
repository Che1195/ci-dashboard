# CI Dashboard

- `CI Dashboard` is a read-only macOS menu-bar monitor for Che's self-hosted GitHub Actions fleet; never add mutating GitHub or runner actions.
- Fleet overview: `~/projects/che-context/Areas/Self-hosted CI.md`.
- Authoritative runner runbook and scripts: `Che1195/trainer-track-v2` (`docs/ci-mac-mini.md`, `ops/ci-mini/`, `ops/ci-studio/`).
- Build & tests: see `README.md` (`xcodegen generate` and `xcodebuild test -project CIDashboard.xcodeproj -scheme CIDashboard -destination 'platform=macOS'`).
