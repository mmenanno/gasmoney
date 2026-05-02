# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.5.0] - 2026-05-02

### Added

- Mobile-first navigation. Below 720 px the topbar collapses to a wordmark + burger button; the nav links slide in from the right as a 280 px panel with a backdrop scrim. `public/nav.js` toggles the panel on burger click, closes on outside-click / Escape / nav-link click, and resets to the desktop layout on resize. Animated burger lines fold into an X when open.
- Vehicles page replaced its desktop-only ledger table with a card-based layout (`.vehicle-card`). Each card stacks the rename input + save button, the "X fillups · manage →" link + pin toggle, and a corner delete (×). Pinned vehicles get a teal left border so the dashboard's at-a-glance set is identifiable at a glance here too. Two cards per row on desktop (≥721 px); single-column stack on mobile.
- iOS PWA safe-area handling. The viewport meta gained `viewport-fit=cover`; the page wrapper, mobile nav panel, and topbar use `env(safe-area-inset-*)` so installed-app content clears the notch and home indicator without overlap.

### Changed

- Wide ledger tables (recent searches, fillups, saved trips) horizontally scroll inside their `.history` container on mobile rather than compress columns past readability. `.ledger { min-width: 480px }` keeps the column widths legible.
- Service-worker cache bumped to `gasmoney-shell-v2`; the precache list now includes `/nav.js` so installed PWAs pick up the navigation script offline-first.
- `.brand__name` is `white-space: nowrap` and shrinks from 28 px → 22 px below 720 px so "Gas Money" no longer wraps.

## [0.4.0] - 2026-05-02

### Removed

- Dropped five `fillups` columns the app never read after writing: `partial_fill`, `fuel_type`, `location`, `city`, `notes`. The `migrate!` step in `lib/db.rb` removes them from existing databases on next boot; SQLite handles the table rebuild via ActiveRecord's `remove_column`. Fillup row counts are unchanged. `partial_fill` was redundant with `l_per_100km IS NULL` (which is what every consumer was already checking); the others were imported from the GasBuddy CSV but never surfaced anywhere.
- Removed the "Location" field from the manual fillup form and the matching `presence_param` helper from `app.rb`.

### Changed

- `Importer.parse_fuel_economy` now returns a single nullable Float instead of a `[Float?, partial_fill_int]` tuple. Callers that previously cared about the `partial_fill` flag use `l_per_100km.nil?` instead, which was already the canonical check inside the calculator.

## [0.3.0] - 2026-05-02

### Added

- Progressive Web App support. Browsers that support PWAs now offer "Add to Home Screen" / "Install app" prompts.
  - `public/manifest.webmanifest` declares `name`, `short_name`, `start_url`, `display: standalone`, dark theme/background colours matching `--bg`, and 192/512 px PNG icons (with `purpose: "any maskable"` for Android adaptive icons) plus the SVG favicon as a vector fallback.
  - `public/sw.js` is a small service worker that pre-caches the static app shell — CSS, JS, manifest, favicon, all PWA icons — and serves them cache-first. HTML, POSTs, redirects, and `/health` are passed straight through to the network so the dashboard and trip-cost calculator never serve stale data. The cache version (`gasmoney-shell-v1`) is bumped whenever the precache list changes.
  - Layout adds `theme-color` (matches `--bg`), Apple `mobile-web-app-*` meta tags, and a service-worker registration shim that fails silently (logs a warning) so older browsers don't break.
- `Sinatra::Base.mime_type :webmanifest, "application/manifest+json"` so Firefox honours `<link rel="manifest">` (the default mapping is `text/plain`).
- `bin/build-icons` now also emits a 192 px variant and copies `icon-192.png` / `icon-512.png` into `public/icons/` for the manifest references.

## [0.2.1] - 2026-05-02

### Changed

- `/vehicles` now exposes a `<count> fillups · manage →` ghost button per row that links to the per-vehicle fillup page. Previously the count was a quiet text link inside the "Fillups" column — discoverable only by hovering. Removes the empty spacer column the table inherited from an earlier layout.

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
