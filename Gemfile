# frozen_string_literal: true

source "https://rubygems.org"

gemspec

gem "digest-blake3", "~> 1.5"
gem "thor", "~> 1.3"

gem "ffi", "~> 1.16.0" if RUBY_VERSION < "3.0"

group :test do
  gem "rake", "~> 13.0", require: false
  gem "rspec", "~> 3.13"
  gem "rubocop", "~> 1.75", require: false
  gem "rubocop-performance", "~> 1.25", require: false
  gem "rubocop-rspec", "~> 3.5", require: false
  gem "simplecov", "~> 0.22", require: false
  gem "simplecov-console", "~> 0.9.5", require: false
  gem "webmock", "~> 3.26"
  gem "yard", "~> 0.9", require: false
end

if RUBY_VERSION >= "3.2"
  gem "rbs", "~> 4.0", require: false, group: :test
  gem "steep", "~> 2.0", require: false, group: :test
elsif RUBY_VERSION >= "3.1"
  gem "rbs", "~> 3.10", require: false, group: :test
  gem "steep", "~> 1.10", require: false, group: :test
elsif RUBY_VERSION >= "3.0"
  gem "rbs", "~> 3.2", require: false, group: :test
  gem "steep", "~> 1.6", require: false, group: :test
else
  gem "rbs", "~> 3.1", require: false, group: :test
  gem "steep", "~> 1.5", require: false, group: :test
end
