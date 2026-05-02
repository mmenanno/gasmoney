# frozen_string_literal: true

require "ferrum"
require "json"
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

      DEFAULT_TIMEOUT = 60      # seconds, total browser lifetime
      LOGIN_NAV_TIMEOUT = 30    # seconds, after submit before we expect /account/*

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

        log(:info, "Launching headless Chromium (#{browser_path})")
        browser = Ferrum::Browser.new(
          headless: true,
          browser_path: browser_path,
          process_timeout: DEFAULT_TIMEOUT,
          timeout: LOGIN_NAV_TIMEOUT,
          window_size: [1280, 800],
          # Some hosting environments (Docker on Unraid in particular)
          # don't permit a sandboxed Chromium child. The risk is
          # smaller for us because we only ever load gasbuddy.com URLs
          # we control the credentials for.
          browser_options: { "no-sandbox" => nil, "disable-dev-shm-usage" => nil },
        )

        run_login(browser, username, password)
      ensure
        begin
          browser&.quit
        rescue StandardError
          # Best-effort. A child process that's already gone or never
          # got a chance to start is fine to ignore here — we're
          # shutting down anyway.
        end
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

      def wait_for_form(page)
        deadline = Time.now + LOGIN_NAV_TIMEOUT
        until form_ready?(page)
          raise LoginFailed, "Login form didn't render within #{LOGIN_NAV_TIMEOUT}s" if Time.now > deadline

          sleep 0.25
        end
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

          raise LoginFailed, "No post-login navigation within #{LOGIN_NAV_TIMEOUT}s (still on #{url})" if Time.now > deadline

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
