# frozen_string_literal: true

source "https://rubygems.org"

# Web
gem "puma",          "~> 8.0"
gem "rackup",        "~> 2.2"
gem "sinatra",       "~> 4.1"

# Data
gem "activerecord",  "~> 8.0"
gem "csv",           "~> 3.3"
gem "sqlite3",       "~> 2.6"

group :development, :test do
  gem "rake"
  gem "rubocop-mmenanno", require: false
  gem "rubocop-rake",     require: false
end

group :test do
  gem "minitest", "~> 6.0"
  gem "minitest-reporters"
  gem "rack-test"
end
