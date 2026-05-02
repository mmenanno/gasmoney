# frozen_string_literal: true

require "ferrum"
require "fileutils"
require "json"
require "tmpdir"
require "uri"

module GasMoney
  module GasBuddy
    # Drives a headless Chromium (via Ferrum/CDP) to perform a real
    # GasBuddy login. The site is fully behind Cloudflare's JS
    # challenge, so any non-browser HTTP client gets blocked. By
    # running the login inside Chromium:
    #
    #   - Cloudflare's challenge is solved naturally (the browser
    #     executes the JS).
    #   - The React form's JSON XHR fires correctly with the right
    #     Content-Type, the per-request `gbcsrf` header, and the
    #     `identifier`/`password`/`return_url` body shape — no need
    #     to reverse-engineer or replay any of it.
    #   - Cookies returned in the response (cf_clearance + auth
    #     cookies) are bound to the browser's TLS fingerprint and
    #     User-Agent, both of which we can reuse for subsequent
    #     plain-HTTP requests since they all come from the same
    #     container/IP.
    #
    # Browser lifetime is scoped to one login attempt. The browser
    # process is started fresh each time refresh_cookies! runs and
    # quit before the method returns.
    class Browser
      class Error < StandardError; end
      class LaunchFailed < Error; end
      class LoginFailed < Error; end

      DEFAULT_BROWSER_PATHS = [
        ENV.fetch("CHROMIUM_PATH", nil),
        "/usr/bin/chromium",
        "/usr/bin/chromium-browser",
        "/usr/bin/google-chrome",
        "/Applications/Chromium.app/Contents/MacOS/Chromium",
        "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
      ].compact.freeze

      LOGIN_URL = "https://iam.gasbuddy.com/login"
      VEHICLES_URL = "https://www.gasbuddy.com/account/vehicles"

      PROCESS_TIMEOUT = 60      # seconds, time for chromium to bind its CDP port
      LOGIN_NAV_TIMEOUT = 60    # seconds, time for any single nav step (form render, post-login redirect)

      # Strips environment variables that would corrupt Chromium's
      # startup. `LD_PRELOAD=libjemalloc` (set in the Dockerfile for
      # the Ruby process) collides with Chromium's PartitionAlloc and
      # crashes the renderer before Ferrum's CDP handshake. The unset
      # is scoped to the Chromium spawn: child Chromium inherits the
      # cleaned env, while puma continues to benefit from jemalloc in
      # this process. Other variables that could trip Chromium (e.g.
      # MALLOC_CONF, the matching jemalloc tunable) are also dropped.
      ENV_KEYS_TO_STRIP = ["LD_PRELOAD", "MALLOC_CONF"].freeze

      def initialize(logger: nil)
        @logger = logger
      end

      # Returns:
      #   { cookies: [{name, value, domain, path, secure, httpOnly, expires}],
      #     user_agent: String,
      #     csrf_token: String,
      #     final_url: String }
      def login(username:, password:)
        browser_path = locate_browser
        data_dir = chromium_data_dir

        log(:info, "Launching Chromium (#{browser_path})")
        browser = with_chromium_env do
          # `headless: false` so Ferrum doesn't add `--headless`. The
          # production launch goes through bin/chromium-xvfb which
          # wraps Chromium in xvfb-run, so it's a real headed browser
          # rendering to a virtual display. Cloudflare's iam.gasbuddy
          # challenge fingerprints any `--headless`/`--headless=new`
          # mode plus the CDP-driver flags Ferrum forces, so headed
          # under Xvfb is the only mode it doesn't block.
          Ferrum::Browser.new(
            headless: false,
            browser_path: browser_path,
            process_timeout: PROCESS_TIMEOUT,
            timeout: LOGIN_NAV_TIMEOUT,
            window_size: [1280, 800],
            browser_options: chromium_flags(data_dir),
          )
        end

        run_login(browser, username, password)
      rescue Ferrum::DeadBrowserError, Ferrum::ProcessTimeoutError => e
        # When Chromium dies before Ferrum can connect, the only
        # actionable signal is the binary's own stderr. We can't
        # capture that from this side (Ferrum spawns the process), so
        # we point the operator at the container logs and surface the
        # underlying timeout/dead-browser distinction in the message.
        raise LaunchFailed,
          "Chromium exited before Ferrum could connect (#{e.class.name.split("::").last}: #{e.message}). " \
          "Inspect chromium stderr in the container logs for the underlying cause."
      ensure
        begin
          browser&.quit
        rescue StandardError
          # Best-effort. A child process that's already gone is fine to
          # ignore here — we're shutting down anyway.
        end
        cleanup_data_dir(data_dir)
      end

      private

      def run_login(browser, username, password)
        page = browser.create_page

        log(:info, "Loading login page (Cloudflare challenge solves here)")
        page.go_to("#{LOGIN_URL}?return_url=#{URI.encode_www_form_component(VEHICLES_URL)}")
        wait_for_form(page)

        csrf = extract_csrf(page)

        log(:info, "Submitting credentials")
        fill_input(page, ['[name="identifier"]', '[type="email"]', '[autocomplete="username"]'], username)
        fill_input(page, ['[name="password"]', '[type="password"]'], password)
        click_submit(page)

        wait_for_post_login(page)

        cookies = page.cookies.all.values.map { |c| serialize_cookie(c) }
        user_agent = page.evaluate("navigator.userAgent").to_s
        final_url = page.url

        if final_url.include?("iam.gasbuddy.com/login")
          # Still on the login page — credentials rejected or another
          # interstitial. Surface a clear error rather than persisting
          # half-authenticated state.
          message = scrape_error_message(page)
          raise LoginFailed, message || "Login form did not redirect away from /login"
        end

        log(:info, "Login complete — landed on #{final_url}, captured #{cookies.size} cookies")

        {
          cookies: cookies,
          user_agent: user_agent,
          csrf_token: csrf,
          final_url: final_url,
        }
      end

      def locate_browser
        path = DEFAULT_BROWSER_PATHS.find { |p| File.executable?(p.to_s) }
        return path if path

        raise LaunchFailed,
          "No Chromium binary found. Set CHROMIUM_PATH or install /usr/bin/chromium."
      end

      # Container-friendly flag set. Each flag has a specific reason:
      #   disable-blink-features=AutomationControlled: hides the
      #     `navigator.webdriver` property that CF's bot heuristics
      #     check first.
      #   no-sandbox: container has no SUID-helper for the sandbox.
      #   disable-dev-shm-usage: Docker's default /dev/shm is 64MB,
      #     which Chromium will exhaust loading non-trivial pages.
      #   disable-gpu: no GPU in the container. We deliberately do NOT
      #     pass --disable-software-rasterizer because Cloudflare's
      #     challenge runs WebGL/canvas fingerprinting and silently
      #     fails (no cf_clearance) when those APIs aren't backed by
      #     either real or software rasterization.
      #   disable-extensions / no-first-run: avoid one-time setup
      #     phases that can stall first launch.
      #   mute-audio: we never want sound.
      #   user-data-dir: explicit writable location so Chromium isn't
      #     racing to create one under /tmp on parallel runs.
      #
      # No `--headless` flag is passed: Chromium runs fully headed
      # against the Xvfb display set up by bin/chromium-xvfb. Both
      # `--headless` and `--headless=new` leave fingerprints that
      # Cloudflare's iam.gasbuddy.com challenge picks up.
      def chromium_flags(data_dir)
        {
          "disable-blink-features" => "AutomationControlled",
          "no-sandbox" => nil,
          "disable-dev-shm-usage" => nil,
          "disable-gpu" => nil,
          "disable-extensions" => nil,
          "no-first-run" => nil,
          "no-default-browser-check" => nil,
          "mute-audio" => nil,
          "user-data-dir" => data_dir,
        }
      end

      def with_chromium_env
        saved = ENV_KEYS_TO_STRIP.to_h { |k| [k, ENV.fetch(k, nil)] }
        ENV_KEYS_TO_STRIP.each { |k| ENV.delete(k) }
        yield
      ensure
        saved.each { |k, v| ENV[k] = v if v }
      end

      def chromium_data_dir
        path = File.join(Dir.tmpdir, "gasmoney-chromium-#{Process.pid}-#{rand(1_000_000)}")
        FileUtils.mkdir_p(path)
        path
      end

      def cleanup_data_dir(path)
        return if path.nil? || !Dir.exist?(path)

        FileUtils.rm_rf(path)
      end

      def wait_for_form(page)
        deadline = Time.now + LOGIN_NAV_TIMEOUT
        until form_ready?(page)
          if Time.now > deadline
            log_page_state(page, "form-render timeout")
            raise LoginFailed, "Login form didn't render within #{LOGIN_NAV_TIMEOUT}s (last url=#{page.url.inspect})"
          end

          sleep 0.25
        end
      end

      # Dumps URL, title, and a body excerpt when a wait condition
      # fails. Without this the operator has no way to tell whether
      # we're stuck on Cloudflare's challenge, a rate-limit page,
      # or a real login form whose selectors no longer match.
      def log_page_state(page, label)
        url = safe_eval(page) { page.url.to_s }
        title = safe_eval(page) { page.title.to_s }
        body = safe_eval(page) { page.evaluate("document.body && document.body.innerText || ''").to_s }
        excerpt = body.gsub(/\s+/, " ").strip[0, 400]
        log(:info, "#{label}: url=#{url.inspect} title=#{title.inspect}")
        log(:info, "#{label}: body=#{excerpt.inspect}")
      end

      def safe_eval(_page)
        yield
      rescue Ferrum::Error, StandardError => e
        "<unavailable: #{e.class.name.split("::").last}>"
      end

      def form_ready?(page)
        # Both fields rendered AND the submit button is enabled. Forms
        # that haven't hydrated yet keep the button disabled.
        result = page.evaluate(<<~JS)
          (() => {
            const id = document.querySelector('input[name="identifier"], input[type="email"], input[autocomplete="username"]');
            const pw = document.querySelector('input[name="password"], input[type="password"]');
            const btn = document.querySelector('button[type="submit"]');
            return Boolean(id && pw && btn);
          })()
        JS
        result == true
      rescue Ferrum::PendingConnectionsError, Ferrum::TimeoutError
        false
      end

      def fill_input(page, selectors, value)
        node = first_match(page, selectors)
        raise LoginFailed, "Couldn't find input matching any of #{selectors.inspect}" unless node

        node.focus
        # Use type rather than set value so React's onChange handlers
        # fire — otherwise the submit button stays disabled.
        node.type(value)
      end

      def click_submit(page)
        page.at_css('button[type="submit"]').click
      end

      def first_match(page, selectors)
        selectors.each do |sel|
          node = page.at_css(sel)
          return node if node
        end
        nil
      end

      def wait_for_post_login(page)
        deadline = Time.now + LOGIN_NAV_TIMEOUT
        loop do
          url = page.url.to_s
          # Success: any URL that isn't iam.gasbuddy.com/login. The
          # form redirects to return_url on success.
          return if !url.include?("iam.gasbuddy.com/login") && !url.empty?

          if Time.now > deadline
            log_page_state(page, "post-login timeout")
            raise LoginFailed, "No post-login navigation within #{LOGIN_NAV_TIMEOUT}s (still on #{url})"
          end

          sleep 0.25
        end
      end

      def extract_csrf(page)
        # The login page sets `window.gbcsrf = "1.xxx"` inline. Read
        # it directly rather than scraping HTML so we don't depend on
        # the surrounding markup.
        page.evaluate("window.gbcsrf || null").to_s
      end

      def scrape_error_message(page)
        page.evaluate(<<~JS) || nil
          (() => {
            const el = document.querySelector('[role="alert"], .error-message, [data-testid*="error"]');
            return el ? el.textContent.trim() : null;
          })()
        JS
      rescue Ferrum::Error
        nil
      end

      def serialize_cookie(cookie)
        {
          name: cookie.name,
          value: cookie.value,
          domain: cookie.domain,
          path: cookie.path,
          secure: cookie.secure?,
          httpOnly: cookie.httponly?,
          expires: cookie.expires&.to_i,
        }.compact
      end

      def log(level, message)
        @logger&.public_send(level, "[gasbuddy] #{message}")
      end
    end
  end
end
