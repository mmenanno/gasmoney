# frozen_string_literal: true

source "https://rubygems.org"

# Web
gem "puma",          "~> 8.0"
gem "rackup",        "~> 2.2"
gem "sinatra",       "~> 4.1"

# Data
gem "activerecord",  "~> 8.0"
gem "csv",           "~> 3.3"
gem "sqlite3",       "~> 2.9"

# GasBuddy auto-sync: Faraday for the HTTP client + cookie persistence,
# Nokogiri for parsing the server-rendered vehicle list page, Ferrum to
# drive a bundled headless Chromium for the login (CF challenge + the
# React form's JSON XHR), rufus-scheduler for the daily cron.
gem "faraday",            "~> 2.14"
gem "faraday-cookie_jar", "~> 0.0.7"
gem "ferrum",             "~> 0.16"
gem "http-cookie",        "~> 1.0"
gem "nokogiri",           "~> 1.18"
gem "rufus-scheduler",    "~> 3.9"

group :development, :test do
  gem "rake"
  gem "rubocop-mmenanno", require: false
  gem "rubocop-rake",     require: false
end

group :test do
  gem "minitest", "~> 6.0"
  gem "minitest-reporters"
  gem "rack-test"
  gem "webmock", "~> 3.25"
end
