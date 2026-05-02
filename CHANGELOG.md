# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.10.1] - 2026-05-02

### Changed

- Sync activity card now surfaces live progress for running runs. Two complementary changes:
  - A "now happening" line above the counters shows the latest log message with a pulsing teal dot. Backfill writes per-year entries (`2025: 14 entries`, `2024: 0 entries`, …) which now stream into this line as they happen — no more blind waiting.
  - The log-entries `<details>` auto-expands while a run is in progress, so the full activity feed is visible without an extra click. The polling JS keeps the latest message in the live line synced with whatever the server has logged most recently.

## [0.10.0] - 2026-05-02

### Added

- **Backfill** button on the Sync page. Walks the GasBuddy fuel-log year-by-year from current down to 2010, stopping after 2 consecutive empty years (so vehicles bought mid-history don't terminate the walk early). Decoupled from regular sync via a new `mode: :recent | :backfill` parameter on `Sync.run`.
- New `GetFuelLogs($guid: ID!, $limit: Int, $year: String)` query at the GraphQL root. Discovered by scraping GasBuddy's `FuelLogBookPage` chunk. Returns one year of entries at a time, which is what makes the backfill possible — the previous `myVehicle.fuelLogs(limit:)` query the SSR uses defaults to current year and has no time filter at all.

### Fixed

- Vehicle linking row hover background painted only on the left cell. Was a `display: flex` rule on `td:last-child` that broke the table-cell paint model. Wrapped the controls in an inner `.linking-controls` flex div instead so the `td` stays a real cell.

### Changed

- Recent sync now uses the same root-level `fuelLogs` query as backfill (with `year: nil`). The previous `MyVehicleFuelLogs` query is gone — keeping a single query path means both modes share the same network/parsing/reconciliation code and we don't have two ways to answer "what fillups exist for this vehicle".

## [0.9.1] - 2026-05-02

### Changed

- "Ignore" is no longer an option in the Vehicle linking dropdown. The dropdown is for linking only; ignoring is a side action — small `ignore` link button next to `save` on each active row, and the affected row moves to a compact "Ignored" footnote at the bottom of the section. Two new endpoints (`POST /sync/vehicles/ignore`, `POST /sync/vehicles/restore`) replace the dropdown's `vehicle_id=ignore` shortcut.
- Linked rows now show a "locked-in" summary (`→ {local vehicle} change ignore`) instead of a live dropdown + save button. Live editing is still one click away via the `change` link, but the rest state communicates "this is settled" instead of looking like a pending action.
- Main nav links now read as links at rest. Each one carries a 1px dotted underline (using `--rule`) plus a few pixels of vertical hit-area; hover and the currently-active page promote it to a solid teal underline. The active page also gets ink-colour text instead of soft-grey, so you always know where you are without reading the URL.
- Ghost buttons (`clear credentials`, `refresh garage`, `clear log`, etc.) get a slightly more visible border. The previous `--rule` colour was nearly invisible against the page background; it now uses `rgba(138,139,142,0.32)` so the affordance reads as clickable.
- "Vehicle linking" rows have left padding now. Vehicle name + UUID were sitting flush against the section edge.

### Added

- Custom file picker on `/import`. Replaces the OS-native file input chrome with the rest of the app's mono/dark language: a `choose file` pill, the selected filename in mono (or a "no file chosen" placeholder), and a tabular `CSV` hint on the right. Native input stays in the DOM for form submission and validation; only the chrome is swapped.

### Removed

- "← back to dashboard" / "← back to vehicles" links at the bottom of `/import`, `/saved_trips`, `/vehicles`, and per-vehicle fillups pages. The main nav lives in the topbar; these were leftovers from earlier without it.

## [0.9.0] - 2026-05-02

### Added

- **Refresh garage** button next to the Vehicle linking heading. Pulls the GasBuddy vehicle list on demand instead of bundling it into every fillup sync, so the linking UI is stable across runs and isn't tied to the most-recent SyncRun's log JSON.
- New `gasbuddy_remote_vehicles` table backs the linking section. Persists each remote vehicle's UUID, display name, ignored flag, and `last_seen_at`. Replaces the previous brittle approach of pulling the list out of `SyncLogEntry.detail` JSON, which made the linking UI disappear whenever the sync log was cleared.
- **Ignore** option in the Vehicle linking dropdown. Marking a remote vehicle ignored makes the sync flow skip it permanently (vs unlinked, which is just "skip until linked"). Ignored rows are visually dimmed in the linking table.
- Fillups ledger now shows a per-row provenance glyph: `↻` (teal) for fillups synced from GasBuddy, `✎` (soft gray) for ones added manually or via CSV import. Hover title spells it out.

### Changed

- The main sync (`POST /sync/run`) no longer fetches the GasBuddy garage on every run. It iterates linked, non-ignored vehicles only, and short-circuits with a friendly message if none exist. The garage is refreshed by the new explicit "Refresh garage" action.
- `Sync` no longer carries the `Discovered remote vehicles` log entry that the UI used to scrape — that information lives in the new table.

## [0.8.7] - 2026-05-02

### Fixed

- Per-vehicle sync hit `Unexpected GasBuddy response 400` for every linked vehicle. Two stacked issues:
  - Cloudflare's WAF on `www.gasbuddy.com` rejects `/graphql` POSTs without an `Origin` + `Referer` header pair pointing at the same origin, returning a bare `Bad Request` 400 that masked the real problem. Browser-issued requests carry these by default; our Faraday client did not. Added them.
  - The actual GraphQL schema is `myVehicle(guid: ID!)`, not the speculative `vehicleFuelLogs(vehicleId: String!)` the original implementation guessed at. Discovered the real shape by reading `window.__APOLLO_STATE__` from a logged-in vehicle page and seeing the cached `myVehicle({"guid": ...}) { fuelLogs(limit:) { results: [FuelLog] } }` keys. Re-wrote the query to match, dropped the obsolete two-step list-then-detail dance (one query returns everything we need), and fixed the variable type to `ID!`.
- Client now surfaces a 400-class response body in the error message instead of the bare `Unexpected GasBuddy response 400`. The original error was indistinguishable from a transport failure; without the body the schema mismatch wasn't diagnosable from the sync log.

### Changed

- `Scraper#parse_fuel_logs` replaces `parse_fuel_log_list` + `parse_fuel_log_detail`. The new GraphQL response carries every field per entry, so flattening `data.myVehicle.fuelLogs.results` directly into `DetailEntry` rows is enough — no fallback shape detection, no per-entry detail call, no second round-trip per fillup.
- "Missing previous" fuel-economy rows (GasBuddy's name for the first fillup of a tank, or any fillup without enough history to compute economy) now correctly surface as `nil` `l_per_100km` instead of being treated as an error.

## [0.8.6] - 2026-05-02

### Changed

- **Vehicle linking** dropdowns now use the project's custom select component instead of the native `<select>`. The native dropdown was the last UI surface still rendering OS chrome (system chevron, OS-default option list) — replacing it with the existing `.select` / `data-select` pattern keeps the cross-page look consistent and picks up the project's tabular-mono option list, teal selected state, and keyboard nav for free. Drops the now-dead `.inline-form--link select` CSS rules and adds a small width/padding override for the linking-row context.

## [0.8.5] - 2026-05-02

### Added

- "Clear log" button on the **Sync activity** card. Wipes every finished sync run and its log entries via the existing `dependent: :destroy` cascade. Live runs (status `running`) are preserved so the worker doesn't try to update a row that vanished mid-run. Confirmed via the project's standard danger-confirm dialog.

## [0.8.4] - 2026-05-02

### Fixed

- Login submit click is now scoped to the form that contains the password field. The login page renders two `<form>` elements — the password login form (button "actions.login") and a "magic link" passwordless form (button "magicLinkButton.emailLink") — and both buttons match `button[type="submit"]`. The bare CSS pick was relying on DOM order, which is fragile under React hydration; if the magic-link button rendered first the click would silently send a login-link email and stay on `/login`, indistinguishable from a hung browser. Submit now finds the password input, walks up to its parent `<form>`, and clicks the submit button inside that form specifically.

### Added

- `Browser#wait_for_post_login` now distinguishes "credentials rejected" from generic post-submit hangs. GasBuddy silently re-renders the same login form on a bad password (no error banner, no toast, just the form again), which previously surfaced as `No post-login navigation within 60s` and looked like an automation failure. After a timeout, we now check whether a login form is still present on the page — if so the error message tells the operator to update credentials on `/sync` rather than diagnose chromium.

## [0.8.3] - 2026-05-02

### Fixed

- GasBuddy login was hanging on Cloudflare's "Just a moment…" interstitial in 0.8.2. With Chromium successfully launching, the next failure surfaced: the iam.gasbuddy.com challenge fingerprints both `--headless` and `--headless=new` modes plus the CDP-driver flags (`--enable-automation`, `--keep-alive-for-test`, etc.) that Ferrum forces on every browser it spawns and which can't be stripped from outside the gem. Switched to running Chromium fully headed against an Xvfb virtual framebuffer — no `--headless` flag at all, just a real browser rendering to a virtual display. Cloudflare treats it like a normal browser and issues `cf_clearance` on first navigation. Adds `xvfb` + `xauth` apt deps and a `bin/chromium-xvfb` wrapper script that `xvfb-run`s the real `/usr/bin/chromium`. `CHROMIUM_PATH` now points at the wrapper so the rest of `Browser` is unchanged.

### Changed

- Dropped `--headless=new`, `--ozone-platform=headless`, and the rest of the headless-mode tuning from `chromium_flags` — irrelevant now that the launch is fully headed. Kept `--disable-blink-features=AutomationControlled` (Cloudflare still checks `navigator.webdriver`) and the rest of the container-friendly flags (no-sandbox, disable-dev-shm-usage, etc.).
- `Browser#wait_for_form` and `Browser#wait_for_post_login` now log the page URL, title, and a 400-char body excerpt when their deadlines hit. Without this the operator had no way to tell whether the timeout was a stuck Cloudflare challenge, a real form whose selectors had drifted, or a network failure. The 0.8.2 production failure (CF interstitial) was identifiable only because of these logs.

### Added

- `bin/test-browser` is now bundled in the runtime image and uses `bundler/setup`, so the local-Docker dev loop can exercise just `Browser.login` from inside the production image.

## [0.8.2] - 2026-05-02

### Fixed

- `Ferrum::DeadBrowserError` reproducing on amd64 deployments after the 0.8.1 dep additions. Root cause was the global `LD_PRELOAD=/usr/lib/x86_64-linux-gnu/libjemalloc.so.2` (set on the Ruby/puma process for memory-fragmentation reasons). Chromium inherits parent env on spawn, and jemalloc's allocator collides with Chromium's PartitionAlloc — the renderer crashes before Ferrum's CDP handshake completes. The dev environment didn't catch this because arm64's library path (`/usr/lib/aarch64-linux-gnu/...`) doesn't match the hardcoded amd64 path, so the preload silently no-ops there. `Browser#login` now scopes a `LD_PRELOAD` + `MALLOC_CONF` unset to the chromium spawn, so child Chromium starts with a clean allocator while puma keeps its jemalloc benefit.
- Slowness budget for the launch handshake bumped to 60s (`PROCESS_TIMEOUT` and `LOGIN_NAV_TIMEOUT`). Cold first-launch on a small ARM home server can exceed the previous 30s on the form-render step.

### Changed

- Trimmed 17 redundant apt packages from the runtime image. `chromium` on debian:trixie-slim already pulls every shared lib it needs (libnss3, libgbm1, libgtk-3-0, libdrm2, etc.) through its regular apt dep tree even with `--no-install-recommends`. The 0.8.1 explicit list was inherited from a Playwright-style "list every transitive lib" pattern that doesn't apply when the distro package manages the deps. Image is now `chromium + fonts-liberation` only (fonts are still needed because absent fonts make Chromium fall back to symbol-only rendering, which Cloudflare flags). Image size drops by ~80 MB.

### Added

- Local Docker dev workflow (`bin/docker-dev`, `docker-compose.dev.yml`). `bin/docker-dev up` builds and runs the production image locally with credentials decrypted from `.env` via dotenvx; `bin/docker-dev shell` execs into the container; `bin/docker-dev sync` triggers a manual sync against the local container. This closes the loop on chromium-environment bugs that previously required a full GHCR push + Unraid pull cycle to reproduce.
- `bin/test-browser` script for fast end-to-end browser smoke tests inside the container. Exercises `Browser.login` directly with `GASBUDDY_USERNAME` / `GASBUDDY_PASSWORD` from env, surfaces ruby errors and chromium stderr in one place. Fastest path to diagnose `Ferrum::DeadBrowserError`-class issues without touching the rest of the app.

## [0.8.1] - 2026-05-02

### Fixed

- `Ferrum::DeadBrowserError` ("Browser is dead or given window is closed") on first sync after the 0.8.0 upgrade. The chromium package on debian:slim doesn't pull all of its runtime shared libs under `--no-install-recommends`; the binary installs fine but exits ~immediately on launch with no actionable diagnostic. The Dockerfile now explicitly installs `libasound2`, `libatk1.0-0`, `libatk-bridge2.0-0`, `libcups2`, `libdrm2`, `libgbm1`, `libgtk-3-0`, `libnspr4`, `libpango-1.0-0`, `libx11-xcb1`, `libxcomposite1`, `libxdamage1`, `libxfixes3`, `libxkbcommon0`, `libxrandr2`, `libxshmfence1`, `libxss1`, `libxtst6`, and `xdg-utils` alongside chromium itself.

### Changed

- Headless Chromium gets a more aggressive container-friendly flag set: `--disable-gpu`, `--disable-software-rasterizer`, `--disable-extensions`, `--no-first-run`, `--no-default-browser-check`, `--mute-audio`. Each is annotated in `lib/gasbuddy/browser.rb` with the specific reason.
- Each browser launch now creates an explicit `--user-data-dir` under `Dir.tmpdir` and removes it after the run, so concurrent or back-to-back syncs don't race on Chromium's default profile path.
- `Ferrum::DeadBrowserError` and `Ferrum::ProcessTimeoutError` are now caught at the launch site and re-raised as `Browser::LaunchFailed` with a message pointing the operator at the container's stderr for the chromium-side diagnostic.

## [0.8.0] - 2026-05-02

### Changed

- **Auth flow now uses a bundled headless Chromium** (via Ferrum) instead of FlareSolverr. The `cf_clearance` cookie that FlareSolverr returned was bound to FlareSolverr's network identity (IP and/or TLS fingerprint), so the gasmoney container couldn't replay it for the JSON login POST — Cloudflare always re-challenged. The bundled-browser approach solves this for good: the login fires from the same container that subsequently makes the data calls, so cookies are inherently portable.

  What this looks like in practice:
  - On `refresh_cookies!`, gasmoney spawns a headless Chromium, navigates to `/login` (Cloudflare's challenge solves naturally), fills the React form (`identifier` + `password` field names verified from a real login trace), clicks submit, waits for the redirect off `/login`, captures cookies + User-Agent + the per-request `gbcsrf` token, and quits the browser.
  - `/account/vehicles` and `/graphql` calls still go through plain Faraday with the captured cookies — the browser only runs during the login step.

### Removed

- FlareSolverr support. The integration is no longer needed; the related UI section, env-var fallback, "Test connection" button, `lib/gasbuddy/flaresolverr.rb`, and its tests are all gone. The unused `gasbuddy_settings.flaresolverr_url` column stays for now so existing DBs don't need a destructive migration.

### Notes for upgraders

- The Docker image grew by ~150 MB due to bundling Chromium. Self-hosted home-server use case justifies the size; the alternative (proxying through an external CF-bypass service) doesn't reliably work for sites whose login is JSON-with-custom-headers like GasBuddy's.
- The `CHROMIUM_PATH` env var lets you point the browser at a different binary if needed; default is `/usr/bin/chromium` (set in the Dockerfile).
- After upgrade, run a manual sync. The first one will spawn a browser, log in fresh, and store auth cookies. Subsequent syncs reuse those cookies for ~30 days (cf_clearance lifespan); after that the browser launches again.

## [0.7.3] - 2026-05-02

### Fixed

- GasBuddy login now actually completes. Previous releases POSTed `username=...&password=...` form-urlencoded to `iam.gasbuddy.com/login` via FlareSolverr, which returned 200 + 3 bootstrap cookies but no auth cookies — the request never reached GasBuddy's login handler because the actual login endpoint requires:
  - `Content-Type: application/json`
  - JSON body with **`identifier`** (not `username`), `password`, `return_url`, and `query`
  - A per-request `gbcsrf` header read from `window.gbcsrf = "1.xxx"` in the login page HTML

  FlareSolverr's `request.post` doesn't support custom Content-Type or extra headers, so it can't replay this directly. The new flow:

  1. GET `/login` via FlareSolverr — solves the Cloudflare challenge and returns the page HTML, the cookies (including `cf_clearance`), and the matching `User-Agent`.
  2. Extract `gbcsrf` from the HTML.
  3. POST the JSON login from this Ruby client with the captured cookies + UA + CSRF header. The `cf_clearance` cookie + matching UA lets the request through Cloudflare without another solve.
  4. Merge auth cookies (from the login response's `Set-Cookie`) with the bootstrap cookies and persist.

  This relies on Cloudflare's `cf_clearance` being portable from the FlareSolverr host's IP to the gasmoney host's IP. If GasBuddy's CF policy is IP-bound the second POST will hit a fresh CF challenge — the client now detects that case and raises a clear `AuthRequired` error pointing at the IP-binding theory rather than failing silently.

## [0.7.2] - 2026-05-02

### Fixed

- HTTP 3xx responses from GasBuddy now route through the auth-required retry path. GasBuddy returns 302 to `iam.gasbuddy.com/login` for any unauthenticated request to `/account/*`; the client previously dropped 302 into the catch-all "Unexpected response" branch and aborted the sync without re-authing. Now any 3xx redirect raises `AuthRequired`, which triggers `refresh_cookies!` and a single retry.
- `refresh_cookies!` now raises `AuthRequired` when FlareSolverr returns 0 cookies. Without this guard, a silently-failed login (wrong credentials, form changed, JS challenge needed for actual login) stored an empty jar that caused an infinite re-auth loop on the next request.

### Changed

- The `Client`'s log output (e.g. "Solving Cloudflare challenge…", "Login succeeded; N cookies stored") now writes to the active `SyncRun` so the auth flow is visible in the UI's per-run log. Previously these went to a logger that was always `nil` in the sync path, making auth failures invisible from the dashboard.

## [0.7.1] - 2026-05-02

### Fixed

- "Test connection" button on `/sync` crashed with `NameError: uninitialized constant GasMoney::GasBuddy::FlareSolverr` in the production container. `lib/gasbuddy/client.rb` referenced the FlareSolverr class but never `require_relative`'d it; the code worked in tests because each test file loaded the file directly, and worked at runtime previously because `Client#refresh_cookies!` is the only path that touches the constant (and only during sync). The new test button is the first place a route handler resolves the constant during request rendering. Added the missing `require_relative "flaresolverr"` to `client.rb` and a pair of web tests that exercise `POST /sync/flaresolverr/test` end-to-end so this kind of missing-require regression won't slip through again.

## [0.7.0] - 2026-05-02

### Added

- "Test connection" button next to the FlareSolverr URL field on `/sync`. Hits `GET /` on whatever URL is in the input field at the moment (so you can validate before saving) and reports the FlareSolverr version on success or a typed error on failure (`Misconfigured` / `Timeout` / `UpstreamFailure`). The status endpoint doesn't trigger a browser launch or a Cloudflare solve, so the test is fast and burns no FlareSolverr resources.

## [0.6.2] - 2026-05-02

### Security

- Scrubbed `encryption.key` from git history via `git filter-repo`. The file was committed by accident in 0.6.1 (auto-generated by a single test run). The keys it contained were never used to encrypt production data — production deployments use a separately-generated key file under `/app/state/encryption.key` — so no real credentials were ever exposed. Force-pushed; existing clones need `git fetch origin && git reset --hard origin/main` to sync. Image rebuilt to invalidate any layer caches.

## [0.6.1] - 2026-05-02

### Fixed

- **Container boot crash on first start** with the auto-sync changes from 0.6.0. The encryption module hardcoded `db/encryption.key` (relative to the source tree's `lib/`), which resolves to `/app/db/encryption.key` inside the container — a directory that doesn't exist and that the `app` user can't create (only `/app/state` and `/app/log` are writable). The default now derives from `GASMONEY_DB_PATH`: the key file lives next to the SQLite database, which keeps it on the bind-mounted state volume across upgrades. `GASMONEY_ENCRYPTION_KEY_PATH` env var still takes precedence.
- Tests no longer leak an `encryption.key` file at the repo root. The 0.6.0 test setup ran `DB.connect(":memory:")`, which then resolved `File.dirname(":memory:")` to `"."` and dumped a random key file at the cwd. The encryption module now short-circuits in-memory mode by generating ephemeral process-lifetime keys instead of writing anything to disk. The leaked file from a single development commit was scrubbed from git history via `git filter-repo`.

## [0.6.0] - 2026-05-02

### Added

- **Auto-sync from GasBuddy.** New `/sync` page with credentials form, FlareSolverr URL config, vehicle linking table, "sync now" button, auto-sync on/off toggle, and an activity feed of the last 10 sync runs (with per-run expandable logs and a colored left rail communicating status). Daily cron at 00:00 UTC via `rufus-scheduler`; manual runs spawn a background thread that posts updates the page polls every 2 s.
- **GasBuddy auto-sync engine** (`lib/gasbuddy/`):
  - `FlareSolverr` client wraps the `/v1` API to clear Cloudflare's challenge.
  - `Client` (Faraday + cookie jar) replays plain HTTP with stored cookies + UA, transparently re-running the FlareSolverr login flow on a 403/cf-mitigated response.
  - `Scraper` parses `/account/vehicles` HTML with Nokogiri and the `/graphql` JSON responses for fuel-log lists / details.
  - `Sync` orchestrator: refreshes cookies if needed, fetches the vehicle list, then for each linked vehicle reconciles fuel-log entries with these rules:
    1. If a local fillup already carries the GasBuddy entry's UUID, skip.
    2. Else look for a manually-imported fillup (no UUID) within ±36 h and ±0.5 L of the remote entry; if found, link it rather than insert a duplicate. CSV-imported data and auto-synced data coexist this way.
    3. Else insert a fresh fillup carrying the UUID.
  - `SyncRun` + `SyncLogEntry` audit tables capture each pass's counts and ordered log messages so the UI can replay what happened, including any per-vehicle errors.
- **At-rest credential encryption** via `ActiveRecord::Encryption` (AES-256-GCM). Encryption keys come from env vars (`GASMONEY_ENCRYPTION_KEY` etc.) or, if absent, are auto-generated and persisted to `db/encryption.key` (mode 0600) on first boot. `gasbuddy_settings.username`, `password`, and `cookies_json` are encrypted columns.
- **dotenvx workflow** for local dev: `.env.example` lists the required vars; `dotenvx encrypt` produces a ciphertext `.env` + a separate `.env.keys` file, both gitignored. `dotenvx run -- bundle exec rackup` injects the decrypted values into the process.
- **PWA refresh button** in the footer that unregisters the service worker, deletes its caches, and hard-reloads — lets installed-PWA users pick up new shells without going to browser settings. Hidden in non-PWA browsers.

### Changed

- License badge in the README switched from `shields.io/github/license` (which has been returning "repo not found" intermittently) to a static `badge/license-MIT-blue` image — both link to the local `LICENSE` file.
- Service worker bumped to `gasmoney-shell-v3`; `nav.js`, `pwa-refresh.js`, and `sync.js` added to the precache list so the new offline shell is consistent with the new pages.
- `vehicles` and `fillups` tables gain `gasbuddy_uuid` / `gasbuddy_entry_uuid` columns with partial unique indexes (`WHERE … IS NOT NULL`) so manual-only data continues to dedup on the existing `(vehicle_id, filled_at, odometer, quantity_liters)` key.

### Security

- GasBuddy credentials and session cookies never appear in logs (no Faraday request-logger middleware enabled), and are only ever sent over HTTPS to GasBuddy / iam.gasbuddy.com or to the user-configured FlareSolverr endpoint.
- The FlareSolverr URL is treated as sensitive — it's a runtime-only setting (env var fallback + UI override), and never committed to source control.

## [0.5.2] - 2026-05-02

### Changed

- Scrubbed `.playwright-mcp/` snapshot YAML files from the entire git history via `git filter-repo --path .playwright-mcp --invert-paths`. They were committed by accident in 0.5.0 and then untracked in 0.5.1, but the binary content lived on as unreachable blobs reachable through old refs. This release rewrites the affected commits (force-push) so the files are gone for good. Existing clones will need to re-clone or `git fetch origin && git reset --hard origin/main` to pick up the rewritten history. All commits remain SSH-signed.

## [0.5.1] - 2026-05-02

### Changed

- `.gitignore` now excludes `.playwright-mcp/`, the scratch directory the Playwright MCP integration writes accessibility-tree snapshots to during interactive testing sessions. The three stray snapshot YAMLs that landed in 0.5.0 are removed from tracking.

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
