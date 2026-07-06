# frozen_string_literal: true

require_relative "src/hugging_face_storage/core/version"

Gem::Specification.new do |spec|
  spec.name          = "hugging_face_storage"
  spec.version       = HuggingFaceStorage::VERSION
  spec.authors       = ["Đăng Khoa"]
  spec.email         = ["i.am@dangkhoa.dev"]

  spec.summary       = "Ruby client for Hugging Face storage (bucket) API with Xet protocol support"
  spec.description   = "A Ruby client library for interacting with Hugging Face storage buckets, " \
                       "supporting file upload/download, directory management, cross-repo copying, " \
                       "and the Xet content-addressable storage protocol."
  spec.homepage      = "https://huggingface.co"
  spec.license       = "MIT"

  spec.required_ruby_version = ">= 2.7"

  spec.metadata["homepage_uri"]    = spec.homepage
  spec.metadata["source_code_uri"] = "https://github.com/dangkhoa/hugging_face_storage"
  spec.metadata["changelog_uri"]   = "https://github.com/dangkhoa/hugging_face_storage/releases"
  spec.metadata["rubygems_mfa_required"] = "true"

  spec.files = Dir["src/**/*.rb"] + Dir["sig/**/*.rbs"] + Dir["ext/**/*.{rb,c}"] + [
    "bin/hfs",
    "Gemfile",
    "LICENSE",
    "README.md",
    "README.vi.md",
    "Steepfile",
  ]
  spec.bindir        = "bin"
  spec.executables   = ["hfs"]
  spec.require_paths = ["src"]
  spec.extensions    = ["ext/gearhash/extconf.rb"]

  spec.add_dependency "digest-blake3", "~> 1.5"
  spec.add_dependency "fiddle"
  spec.add_dependency "json"
  spec.add_dependency "thor", "~> 1.3"

  spec.add_development_dependency "base64", "~> 0.2"
  spec.add_development_dependency "benchmark"
  spec.add_development_dependency "bundler-audit", "~> 0.9"
  spec.add_development_dependency "rake", "~> 13.0"
  spec.add_development_dependency "rspec", "~> 3.13"
  spec.add_development_dependency "rubocop", "~> 1.75"
  spec.add_development_dependency "rubocop-performance", "~> 1.25"
  spec.add_development_dependency "rubocop-rspec", "~> 3.5"
  spec.add_development_dependency "simplecov", "~> 0.22"
  spec.add_development_dependency "simplecov-console", "~> 0.9.5"
  spec.add_development_dependency "webmock", "~> 3.26"
  spec.add_development_dependency "yard", "~> 0.9"
end
