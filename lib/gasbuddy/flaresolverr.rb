# frozen_string_literal: true

require "faraday"
require "json"

module GasMoney
  module GasBuddy
    # Thin wrapper over FlareSolverr's `/v1` endpoint. Used to obtain
    # auth cookies past Cloudflare's JS challenge — once we have the
    # cookies, the rest of the sync uses plain Faraday with no need
    # to round-trip through FlareSolverr.
    #
    # The instance URL is sensitive (operator-private). Callers pass
    # it in; this class does NOT read environment variables directly.
    class FlareSolverr
      class Error < StandardError; end
      class Misconfigured < Error; end
      class Timeout < Error; end
      class UpstreamFailure < Error; end

      DEFAULT_TIMEOUT_MS = 60_000
      OPEN_TIMEOUT       = 10
      READ_TIMEOUT       = 75

      def initialize(endpoint)
        url = endpoint.to_s.strip
        raise Misconfigured, "FlareSolverr URL is required" if url.empty?
        raise Misconfigured, "FlareSolverr URL must be an http(s) URL" unless url.match?(%r{\Ahttps?://[^\s]+\z})

        @endpoint = url.chomp("/")
      end

      # Submits a login POST through FlareSolverr's headless browser
      # and returns the cookie jar / user-agent / response HTML.
      #
      # `post_data` is a URL-encoded form body (e.g. "username=...&password=...").
      def login(login_url:, post_data:, max_timeout_ms: DEFAULT_TIMEOUT_MS)
        post_to_solver(
          cmd: "request.post",
          url: login_url,
          postData: post_data,
          maxTimeout: max_timeout_ms,
        )
      end

      # Fetches a URL through FlareSolverr (used as a fallback when a
      # request hits a CF challenge mid-session).
      def get(url:, cookies: [], max_timeout_ms: DEFAULT_TIMEOUT_MS)
        post_to_solver(
          cmd: "request.get",
          url: url,
          cookies: cookies,
          maxTimeout: max_timeout_ms,
        )
      end

      # Cheap connectivity check. FlareSolverr exposes a JSON status
      # blob at GET /, including its version. Doesn't trigger a
      # browser launch or a Cloudflare solve — just confirms the URL
      # we have configured points at a real FlareSolverr instance.
      def ping
        response = connection.get("/")
        body = parse_body(response.body)
        msg = body["msg"].to_s
        unless msg.start_with?("FlareSolverr")
          raise UpstreamFailure, "Unexpected response from #{@endpoint}: #{msg.empty? ? body.inspect : msg}"
        end

        { version: body["version"], message: msg, user_agent: body["userAgent"] }
      rescue Faraday::TimeoutError => e
        raise Timeout, "FlareSolverr did not respond in time: #{e.message}"
      rescue Faraday::ConnectionFailed => e
        raise UpstreamFailure, "FlareSolverr unreachable: #{e.message}"
      end

      private

      def post_to_solver(payload)
        response = connection.post("/v1") do |req|
          req.headers["Content-Type"] = "application/json"
          req.body = JSON.generate(payload)
        end

        body = parse_body(response.body)
        raise UpstreamFailure, "FlareSolverr replied: #{body["message"] || body.inspect}" unless body["status"] == "ok"

        solution = body["solution"] || {}
        {
          status: solution["status"]&.to_i,
          url: solution["url"],
          html: solution["response"],
          cookies: Array(solution["cookies"]),
          user_agent: solution["userAgent"],
          headers: solution["headers"] || {},
        }
      rescue Faraday::TimeoutError => e
        raise Timeout, "FlareSolverr did not respond in time: #{e.message}"
      rescue Faraday::ConnectionFailed => e
        raise UpstreamFailure, "FlareSolverr unreachable: #{e.message}"
      end

      def parse_body(raw)
        JSON.parse(raw.to_s)
      rescue JSON::ParserError => e
        raise UpstreamFailure, "FlareSolverr returned non-JSON response: #{e.message}"
      end

      def connection
        @connection ||= Faraday.new(url: @endpoint) do |f|
          f.options.open_timeout = OPEN_TIMEOUT
          f.options.timeout      = READ_TIMEOUT
          f.adapter(Faraday.default_adapter)
        end
      end
    end
  end
end
