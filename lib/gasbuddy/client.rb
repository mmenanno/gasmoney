# frozen_string_literal: true

require "faraday"
require "faraday/cookie_jar"
require "http-cookie"
require "json"
require "nokogiri"

require_relative "flaresolverr"

module GasMoney
  module GasBuddy
    # HTTP client for authenticated GasBuddy traffic. The Cloudflare
    # gate is solved once via FlareSolverr (yielding cookies + a
    # matching User-Agent); afterwards plain Faraday calls work as
    # long as we present those cookies and UA together. On a 403/cf-
    # mitigated response we re-run the login flow and retry once.
    #
    # Credentials and the FlareSolverr URL are loaded out of
    # GasbuddySetting and never logged.
    class Client
      class Error < StandardError; end
      class AuthRequired < Error; end
      class RateLimited < Error; end
      class Blocked < Error; end

      BASE_URL    = "https://www.gasbuddy.com"
      LOGIN_URL   = "https://iam.gasbuddy.com/login"
      OPEN_TIMEOUT = 10
      READ_TIMEOUT = 30

      def initialize(setting:, flaresolverr_url:, logger: nil)
        @setting = setting
        @flaresolverr_url = flaresolverr_url
        @logger = logger
      end

      def get(path, headers: {})
        request(:get, path, headers: headers)
      end

      def post(path, body:, headers: {})
        request(:post, path, body: body, headers: headers)
      end

      def post_graphql(operation_name:, variables:, query:)
        body = JSON.generate(operationName: operation_name, variables: variables, query: query)
        post(
          "/graphql",
          body: body,
          headers: {
            "Content-Type" => "application/json",
            "Accept" => "application/json",
            "apollo-require-preflight" => "true",
            "gbcsrf" => @setting.csrf_token.to_s,
          },
        )
      end

      def authenticated?
        # We don't know the exact name of GasBuddy's session cookie, so
        # treat "we have any cookies stored" as the signal that we tried
        # to authenticate at some point. If the session has actually
        # expired the next request returns 403 and the retry path
        # transparently runs the FlareSolverr login flow.
        parsed_cookies.any?
      end

      def refresh_cookies!
        raise Error, "FlareSolverr URL not configured" if @flaresolverr_url.to_s.strip.empty?
        raise Error, "GasBuddy credentials not set" unless @setting.credentials_present?

        log(:info, "Solving Cloudflare challenge and logging in via FlareSolverr")
        solver = FlareSolverr.new(@flaresolverr_url)
        result = solver.login(
          login_url: LOGIN_URL,
          post_data: URI.encode_www_form(
            username: @setting.username,
            password: @setting.password,
          ),
        )

        raise AuthRequired, "FlareSolverr login returned HTTP #{result[:status]}" if result[:status] && result[:status] >= 400

        cookies = serialize_cookies(result[:cookies])
        if cookies.empty?
          # FlareSolverr says "ok" but no cookies came back. Either the
          # POST didn't actually log in (wrong creds, form changed, JS
          # challenge required) or the headless browser dropped the
          # cookies. Refusing to store an empty jar avoids an infinite
          # auth-required → re-auth → 0-cookies → auth-required loop.
          raise AuthRequired, "FlareSolverr returned 0 cookies — login likely failed"
        end

        csrf = extract_csrf_token(result[:html])
        @setting.update!(
          cookies_json:        cookies.to_json,
          user_agent:          result[:user_agent],
          csrf_token:          csrf,
          cookies_fetched_at:  Time.now.utc.iso8601,
        )
        @setting.reload
        @connection = nil
        log(:info, "Login succeeded; #{cookies.size} cookies stored")
      end

      private

      def request(method, path, body: nil, headers: {})
        attempts = 0
        begin
          attempts += 1
          ensure_authenticated!
          response = connection.run_request(method, path, body, default_headers.merge(headers))
          handle_response(response)
        rescue AuthRequired
          raise if attempts > 1

          refresh_cookies!
          retry
        end
      end

      def handle_response(response)
        case response.status
        when 200..299
          response
        when 301, 302, 303, 307, 308
          # GasBuddy redirects unauthenticated browsers to
          # iam.gasbuddy.com/login. Treat any redirect to the IAM
          # subdomain as "auth required"; other redirects (e.g.
          # canonicalisation) we still treat as auth-required to be
          # safe — re-auth is idempotent.
          location = response.headers["location"].to_s
          raise AuthRequired, "Redirected to #{location} — session needs refreshing"
        when 401
          raise AuthRequired, "GasBuddy returned 401"
        when 403
          raise AuthRequired, "Cloudflare challenge — need to refresh cookies" if response.headers["cf-mitigated"]&.include?("challenge")

          raise Blocked, "GasBuddy returned 403 (not a CF challenge)"

        when 429
          raise RateLimited, "GasBuddy returned 429 (rate limited)"
        when 500..599
          raise Error, "GasBuddy returned #{response.status}"
        else
          raise Error, "Unexpected GasBuddy response #{response.status}"
        end
      end

      def ensure_authenticated!
        refresh_cookies! if !authenticated? || @setting.cookies_json.to_s.empty?
      end

      def connection
        @connection ||= Faraday.new(url: BASE_URL) do |f|
          f.options.open_timeout = OPEN_TIMEOUT
          f.options.timeout      = READ_TIMEOUT
          f.headers["User-Agent"] = @setting.user_agent if @setting.user_agent.to_s != ""
          f.use(:cookie_jar, jar: cookie_jar)
          f.adapter(Faraday.default_adapter)
        end
      end

      def cookie_jar
        @cookie_jar ||= HTTP::CookieJar.new.tap do |jar|
          parsed_cookies.each do |c|
            jar.add(
              HTTP::Cookie.new(
                c[:name],
                c[:value].to_s,
                domain: c[:domain] || "www.gasbuddy.com",
                path:   c[:path] || "/",
                secure: c[:secure] || false,
                expires: c[:expires] ? Time.at(c[:expires]).utc : nil,
                for_domain: true,
              ),
            )
          rescue ArgumentError
            # Skip malformed cookies rather than aborting the entire jar.
            next
          end
        end
      end

      def default_headers
        {
          "Accept" => "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
          "Accept-Language" => "en-US,en;q=0.9",
        }
      end

      def parsed_cookies
        return [] if @setting.cookies_json.to_s.empty?

        JSON.parse(@setting.cookies_json, symbolize_names: true)
      rescue JSON::ParserError
        []
      end

      def serialize_cookies(cookies)
        cookies.map do |c|
          {
            name: c["name"],
            value: c["value"],
            domain: c["domain"],
            path: c["path"],
            secure: c["secure"],
            expires: c["expires"],
            httpOnly: c["httpOnly"],
          }.compact
        end
      end

      def extract_csrf_token(html)
        return if html.to_s.empty?

        # The page renders a meta or window.__NEXT_DATA__ blob with the
        # CSRF token. Easiest extraction is via a regex against the raw
        # HTML so we don't depend on the exact server-side framework.
        match = html.match(/"csrfToken"\s*:\s*"([^"]+)"/) ||
          html.match(/gbcsrf['"]?\s*:\s*['"]([^'"]+)/)
        match && match[1]
      end

      def log(level, message)
        @logger&.public_send(level, "[gasbuddy] #{message}")
      end
    end
  end
end
