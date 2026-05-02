# frozen_string_literal: true

require "faraday"
require "faraday/cookie_jar"
require "http-cookie"
require "json"
require "nokogiri"
require "uri"

require_relative "flaresolverr"

module GasMoney
  module GasBuddy
    # HTTP client for authenticated GasBuddy traffic.
    #
    # Auth flow (refresh_cookies!):
    #   1. GET https://iam.gasbuddy.com/login through FlareSolverr to
    #      clear Cloudflare's JS challenge. Captures cookies (including
    #      cf_clearance) + the matching User-Agent + the per-request
    #      `gbcsrf` token rendered into the page HTML.
    #   2. POST JSON {identifier, password, return_url} directly to
    #      iam.gasbuddy.com/login from this Ruby client, presenting
    #      the cookies + UA + gbcsrf header captured in step 1. The
    #      cf_clearance cookie + matching UA lets the request through
    #      Cloudflare without another JS solve. Successful login
    #      returns 200 + sets the auth cookies via Set-Cookie.
    #   3. The merged cookie jar (CF clearance + auth cookies) is
    #      persisted to the GasbuddySetting row, encrypted at rest.
    #
    # On any subsequent 3xx/401/403-cf request, refresh_cookies! re-runs.
    class Client
      class Error < StandardError; end
      class AuthRequired < Error; end
      class RateLimited < Error; end
      class Blocked < Error; end

      BASE_URL    = "https://www.gasbuddy.com"
      IAM_URL     = "https://iam.gasbuddy.com"
      LOGIN_URL   = "#{IAM_URL}/login".freeze
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
        # expired the next request returns 403/302 and the retry path
        # transparently runs the FlareSolverr login flow.
        parsed_cookies.any?
      end

      def refresh_cookies!
        raise Error, "FlareSolverr URL not configured" if @flaresolverr_url.to_s.strip.empty?
        raise Error, "GasBuddy credentials not set" unless @setting.credentials_present?

        log(:info, "Solving Cloudflare challenge via FlareSolverr")
        cf_cookies, user_agent, csrf = fetch_login_page_through_solver

        log(:info, "Got #{cf_cookies.size} bootstrap cookies + CSRF token; submitting login")
        auth_cookies = post_login_json(cf_cookies, user_agent, csrf)

        merged = merge_cookies(cf_cookies, auth_cookies)
        @setting.update!(
          cookies_json:        merged.to_json,
          user_agent:          user_agent,
          csrf_token:          csrf,
          cookies_fetched_at:  Time.now.utc.iso8601,
        )
        @setting.reload
        @connection = nil
        log(:info, "Login succeeded; #{merged.size} cookies stored (#{auth_cookies.size} from auth response)")
      end

      private

      # Step 1 of the auth flow. FlareSolverr loads /login in a real
      # browser, solves the CF challenge, and returns the resulting
      # HTML + cookies + the User-Agent it used. We extract the
      # gbcsrf token from the HTML's `window.gbcsrf = "..."` literal.
      def fetch_login_page_through_solver
        solver = FlareSolverr.new(@flaresolverr_url)
        result = solver.get(url: LOGIN_URL)

        raise AuthRequired, "FlareSolverr returned HTTP #{result[:status]}" if result[:status] && result[:status] >= 400

        cookies = serialize_cookies(result[:cookies])
        raise AuthRequired, "FlareSolverr returned 0 cookies from /login" if cookies.empty?

        csrf = extract_csrf_token(result[:html])
        raise AuthRequired, "Couldn't find gbcsrf token in login page HTML" if csrf.nil? || csrf.empty?

        [cookies, result[:user_agent], csrf]
      end

      # Step 2 of the auth flow. Direct JSON POST from this Ruby client,
      # carrying the CF clearance cookies + matching UA + CSRF header.
      # No FlareSolverr involved — once CF is cleared, plain HTTP works
      # for the rest of this exchange. Returns the auth cookies that
      # came back via Set-Cookie.
      def post_login_json(cf_cookies, user_agent, csrf)
        conn = Faraday.new(url: IAM_URL) do |f|
          f.options.open_timeout = OPEN_TIMEOUT
          f.options.timeout      = READ_TIMEOUT
          f.adapter(Faraday.default_adapter)
        end

        body = {
          identifier: @setting.username,
          password: @setting.password,
          return_url: "#{BASE_URL}/account/vehicles",
          query: "?return_url=#{BASE_URL}/account/vehicles",
        }

        response = conn.post("/login") do |req|
          req.headers["User-Agent"]    = user_agent if user_agent.to_s != ""
          req.headers["Content-Type"]  = "application/json"
          req.headers["Accept"]        = "application/json"
          req.headers["Origin"]        = IAM_URL
          req.headers["Referer"]       = LOGIN_URL
          req.headers["gbcsrf"]        = csrf
          req.headers["Cookie"]        = cookie_header(cf_cookies)
          req.body = JSON.generate(body)
        end

        unless (200..299).cover?(response.status)
          if response.status == 403 && response.headers["cf-mitigated"]&.include?("challenge")
            raise AuthRequired,
              "Login POST hit a Cloudflare challenge — cf_clearance cookie may be IP-bound to the FlareSolverr host"
          end

          message = parse_error_message(response.body) || "HTTP #{response.status}"
          raise AuthRequired, "Login failed: #{message}"
        end

        parse_set_cookie_headers(response)
      end

      def merge_cookies(*lists)
        # Later cookies (auth response) override earlier ones (CF
        # bootstrap) when names collide.
        lists.flatten.to_h { |c| [c[:name], c] }.values
      end

      def cookie_header(cookies)
        cookies.map { |c| "#{c[:name]}=#{c[:value]}" }.join("; ")
      end

      def parse_set_cookie_headers(response)
        # Faraday delivers Set-Cookie as a single string with multiple
        # cookies separated by commas — except commas can also appear
        # inside cookie values (e.g. expires dates). Use HTTP::Cookie
        # to parse correctly.
        raw = response.headers["set-cookie"]
        return [] if raw.to_s.empty?

        host = URI.parse(IAM_URL).host
        HTTP::Cookie.parse(raw, IAM_URL).map do |c|
          {
            name: c.name,
            value: c.value,
            domain: c.domain || host,
            path: c.path,
            secure: c.secure?,
            httpOnly: c.httponly?,
            expires: c.expires&.to_i,
          }.compact
        end
      end

      def parse_error_message(body)
        return if body.to_s.empty?

        parsed = JSON.parse(body.to_s)
        parsed["message"] || parsed["error"] || parsed.dig("error", "message")
      rescue JSON::ParserError
        body.to_s.slice(0, 200)
      end

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
          # iam.gasbuddy.com/login. Re-auth is idempotent so we treat
          # any 3xx as "session needs refreshing" — even canonicalisation
          # redirects, since they're rare on /account paths.
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

        # GasBuddy renders the per-request CSRF as a JS literal in the
        # login page <script> tag: `window.gbcsrf = "1.xxx"`. Match
        # that exact form first; fall back to looser patterns for
        # forward-compat.
        match = html.match(/window\.gbcsrf\s*=\s*"([^"]+)"/) ||
          html.match(/"csrfToken"\s*:\s*"([^"]+)"/) ||
          html.match(/gbcsrf['"]?\s*:\s*['"]([^'"]+)/)
        match && match[1]
      end

      def log(level, message)
        @logger&.public_send(level, "[gasbuddy] #{message}")
      end
    end
  end
end
