# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.2.0] - 2026-05-02

### Added

- Manual fillup entry per vehicle. New page at `/vehicles/:id/fillups` with a form that mirrors the GasBuddy CSV row shape (filled-at, total cost, quantity, unit price, odometer, optional L/100km, optional location) plus a delete-with-confirm history table. Fillup count on `/vehicles` is now a link into this page. Same dedup key as CSV imports — a manually-entered fillup that collides with an imported row produces a `RecordNotUnique` flash.
- Custom confirm dialog component (`public/confirm.js` + `.modal-overlay` styles). Forms opt in via `data-confirm` / `data-confirm-action` / `data-confirm-tone="danger|default"`. Replaces the native `window.confirm()` previously used on the vehicle delete row, and applies it consistently to recent-search, saved-trip, and fillup deletes. Default-focuses Cancel, traps Tab focus, dismisses on Escape and overlay click.
- Footer now shows the running app version (read once at boot from `VERSION` into `GasMoney::VERSION`).

### Changed

- Disabled JetBrains Mono programming ligatures globally (`font-variant-ligatures: none` + `font-feature-settings: "liga" 0, "calt" 0`). User-typed strings like `Person <> Place` were rendering with `<>` fused into a single diamond glyph; the cure is to turn ligatures off site-wide. Programming ligatures aren't useful in a data-display context.
- Footer copy trimmed: "local SQLite · GasBuddy CSV imports · github.com/mmenanno/gasmoney" → "github.com/mmenanno/gasmoney · v\<version\>".

## [0.1.3] - 2026-05-02

### Added

- Inline app icon next to the "Gas Money" wordmark in the topbar (`<img src="/favicon.svg">`). The same SVG was already wired as the browser-tab favicon and apple-touch icon since 0.1.0; this exposes it inside the page chrome too so it's visible without inspecting the tab bar.

## [0.1.2] - 2026-05-02

### Changed

- Bumped Puma to `~> 8.0` (lockfile lands on 8.0.1, was 6.6.1). All other gems were already at the latest version compatible with the existing pessimistic constraints; ran `bundle update --all` to refresh the full lockfile alongside the Puma jump. The only remaining outdated gem is `mustermann` 4.0.0, which is pinned to `~> 3` by Sinatra 4's gemspec — no first-party action available until a newer Sinatra release widens its constraint.

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
