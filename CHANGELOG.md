# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.1.1] - 2026-05-02

### Added

- `.githooks/pre-push` blocks pushes to `main` when `VERSION` hasn't changed relative to the remote tip, mirroring the same release-irrelevant exemptions (`*.md`, `LICENSE`, `.github/**`, `.githooks/**`) that CI's `version-bump-check` job uses. `bin/setup-hooks` activates the hook via `git config core.hooksPath .githooks`.

### Changed

- `lint.yml` and `test.yml` are now `workflow_call`-only; `pull_request` and `push` triggers were removed because they fired alongside the `uses:` invocation from `ci.yml` and produced duplicate "lint" and "test" check runs in the PR UI.
- `version-bump-check` now exempts paths under `.githooks/` so a hook-only push doesn't demand a `VERSION` bump (kept in sync with the pre-push hook's filter).

## [0.1.0] - 2026-05-02

### Added

- Initial public release.
- Sinatra + ActiveRecord + SQLite stack with a single-page dashboard for trip-cost estimates.
- CSV import of GasBuddy fuel logs with row-level dedup on `(vehicle, filled_at, odometer, quantity)`.
- Trip cost calculator with four selection strategies (`exact` / `between` / `after_latest` / `before_earliest`).
- Cost-per-km dashboard tiles (latest fillup + 5-fillup average) for vehicles pinned to the dashboard.
- Saved trips: name + base km + round-trip flag, applied to the calculator with one click.
- Vehicle management: add / edit / delete / pin vehicles independently of imported logs.
- Custom dark-mode select component (keyboard-navigable, ARIA-labelled) replacing native `<select>`.
- Multistage Dockerfile, `docker-compose.yml`, `bin/init` (PUID/PGID/UMASK), `bin/start`, `/health` endpoint.
- GitHub Actions CI: reusable `lint.yml` (RuboCop) + `test.yml` (Minitest with process-parallel ActiveSupport::TestCase), and a multi-arch GHCR publishing pipeline.
- Comprehensive test suite using `ActiveSupport::TestCase` with process-based parallelism and per-worker in-memory SQLite.
