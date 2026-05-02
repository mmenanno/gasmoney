# frozen_string_literal: true

require "test_helper"
require "gasbuddy/flaresolverr"

class GasBuddyFlareSolverrTest < ActiveSupport::TestCase
  test "constructor rejects empty URLs" do
    assert_raises(GasMoney::GasBuddy::FlareSolverr::Misconfigured) do
      GasMoney::GasBuddy::FlareSolverr.new("")
    end
  end

  test "constructor rejects non-http URLs" do
    assert_raises(GasMoney::GasBuddy::FlareSolverr::Misconfigured) do
      GasMoney::GasBuddy::FlareSolverr.new("ftp://example.org")
    end
  end

  test "login returns parsed solution on a 'status: ok' response" do
    stub_request(:post, "http://flare.test/v1")
      .with(body: hash_including("cmd" => "request.post"))
      .to_return(
        status: 200,
        body: JSON.generate(
          status: "ok",
          solution: {
            url: "https://www.gasbuddy.com/account/vehicles",
            status: 200,
            response: "<html>...</html>",
            cookies: [{ "name" => "_gb", "value" => "abc", "domain" => ".gasbuddy.com" }],
            userAgent: "Mozilla/5.0 (test)",
            headers: {},
          },
        ),
        headers: { "Content-Type" => "application/json" },
      )

    result = GasMoney::GasBuddy::FlareSolverr.new("http://flare.test")
      .login(login_url: "https://iam.gasbuddy.com/login",
        post_data: "username=u&password=p")

    assert_equal(200, result[:status])
    assert_equal("Mozilla/5.0 (test)", result[:user_agent])
    assert_equal("_gb", result[:cookies].first["name"])
  end

  test "login raises UpstreamFailure when the solver replies status != ok" do
    stub_request(:post, "http://flare.test/v1")
      .to_return(
        status: 200,
        body: JSON.generate(status: "error", message: "captcha unsolvable"),
        headers: { "Content-Type" => "application/json" },
      )

    assert_raises(GasMoney::GasBuddy::FlareSolverr::UpstreamFailure) do
      GasMoney::GasBuddy::FlareSolverr.new("http://flare.test")
        .login(login_url: "https://iam.gasbuddy.com/login",
          post_data: "username=u&password=p")
    end
  end

  test "login raises UpstreamFailure when the solver returns non-JSON" do
    stub_request(:post, "http://flare.test/v1")
      .to_return(status: 200, body: "<html>not json</html>")

    assert_raises(GasMoney::GasBuddy::FlareSolverr::UpstreamFailure) do
      GasMoney::GasBuddy::FlareSolverr.new("http://flare.test")
        .login(login_url: "https://iam.gasbuddy.com/login",
          post_data: "username=u")
    end
  end
end
