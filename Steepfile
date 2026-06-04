# frozen_string_literal: true

target :lib do
  signature "sig"

  ignore "src/hugging_face_storage/ops/lister.rb" if RUBY_VERSION < "3.1"
  ignore "src/hugging_face_storage/xet/xet_lazy_file.rb" if RUBY_VERSION < "3.1"

  check "src/hugging_face_storage"

  library "delegate"
  library "net-http"
  library "uri"
  library "json"
  library "digest"
  library "fileutils"
  library "cgi"
  library "tsort"
  library "monitor"
  library "logger"
  library "tempfile"
  library "yaml"
  library "timeout"
  library "openssl"
  library "socket"
  library "securerandom"
end
