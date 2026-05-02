# frozen_string_literal: true

require "faraday"
require "faraday/cookie_jar"
require "http-cookie"
require "json"

require_relative "browser"

module GasMoney
  module GasBuddy
    # HTTP client for authenticated GasBuddy traffic.
    #
    # Auth flow (refresh_cookies!): drives a bundled headless Chromium
    # via Ferrum to log in. Cloudflare's challenge solves naturally
    # inside the browser, the React form submits its JSON XHR exactly
    # the way it would for a human user, and we capture the resulting
    # cookies + User-Agent for re-use.
    #
    # Subsequent /account/vehicles + /graphql calls go through plain
    # Faraday with the captured cookies and matching UA. They share
    # the container's IP and TLS fingerprint with the browser session,
    # so Cloudflare lets them through without another JS solve.
    #
    # On any 3xx/401/403-cf response, refresh_cookies! re-runs.
    class Client
      class Error < StandardError; end
      class AuthRequired < Error; end
      class RateLimited < Error; end
      class Blocked < Error; end

      BASE_URL     = "https://www.gasbuddy.com"
      OPEN_TIMEOUT = 10
      READ_TIMEOUT = 30

      def initialize(setting:, logger: nil)
        @setting = setting
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
            "Accept" => "*/*",
            "apollo-require-preflight" => "true",
            "gbcsrf" => @setting.csrf_token.to_s,
            # Cloudflare's WAF on www.gasbuddy.com rejects /graphql with
            # a plain "Bad Request" 400 when Origin/Referer are absent or
            # don't match the site — those headers tell the WAF the call
            # is same-origin from the user's session (which it is, just
            # via Faraday rather than the browser fetch wrapper).
            "Origin" => BASE_URL,
            "Referer" => "#{BASE_URL}/account/vehicles",
          },
        )
      end

      def authenticated?
        # Treat "we have any cookies stored" as "we tried to authenticate
        # at some point". If the session has expired the next request
        # returns 3xx/403/401 and the retry path transparently runs the
        # browser-driven login flow.
        parsed_cookies.any?
      end

      def refresh_cookies!
        raise Error, "GasBuddy credentials not set" unless @setting.credentials_present?

        result = Browser.new(logger: @logger).login(
          username: @setting.username,
          password: @setting.password,
        )

        cookies = result[:cookies]
        raise AuthRequired, "Browser login returned no cookies" if cookies.empty?

        @setting.update!(
          cookies_json:       cookies.to_json,
          user_agent:         result[:user_agent],
          csrf_token:         result[:csrf_token],
          cookies_fetched_at: Time.now.utc.iso8601,
        )
        @setting.reload
        @connection = nil
        log(:info, "Stored #{cookies.size} cookies; UA = #{result[:user_agent].to_s.slice(0, 60)}")
      rescue Browser::LaunchFailed => e
        raise Error, "Couldn't launch headless browser: #{e.message}"
      rescue Browser::LoginFailed => e
        raise AuthRequired, "Login failed: #{e.message}"
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
          # iam.gasbuddy.com/login. Re-auth is idempotent so we treat
          # any 3xx as "session needs refreshing".
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
          # Capture a body snippet so GraphQL field-not-found / variable-
          # type errors are diagnosable from the sync log without having
          # to attach a debugger to the running container.
          body_snippet = response.body.to_s[0, 400]
          raise Error, "Unexpected GasBuddy response #{response.status}: #{body_snippet}"
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

      def log(level, message)
        @logger&.public_send(level, "[gasbuddy] #{message}")
      end
    end
  end
end
