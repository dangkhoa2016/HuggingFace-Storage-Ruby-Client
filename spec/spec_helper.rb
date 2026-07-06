# frozen_string_literal: true

require "webmock/rspec"
require "stringio"
require "json"
require "fileutils"
require "tmpdir"
require "base64"
require "time"

$LOAD_PATH.unshift(File.expand_path("../src", __dir__))
gearhash_ext = File.expand_path("../ext/gearhash", __dir__)
$LOAD_PATH.unshift(gearhash_ext) if File.directory?(gearhash_ext)
require "hugging_face_storage"

WebMock.disable_net_connect!

Dir[File.expand_path("support/**/*.rb", __dir__)].each { |f| require f }

RSpec.configure do |config|
  config.filter_run_excluding :slow unless ENV["RUN_SLOW"]
  config.filter_run_excluding :integration unless ENV["RUN_INTEGRATION"]

  config.expect_with :rspec do |expectations|
    expectations.include_chain_clauses_in_custom_matcher_descriptions = true
  end

  config.mock_with :rspec do |mocks|
    mocks.verify_partial_doubles = true
  end

  config.shared_context_metadata_behavior = :apply_to_host_groups
  config.filter_run_when_matching :focus
  config.order = :random
  Kernel.srand config.seed
end

module TestHelpers
  def stub_auth
    instance_double(HuggingFaceStorage::Authentication,
      token: "hf_test_token_123",
      auth_header: { "Authorization" => "Bearer hf_test_token_123" },
      valid?: true
    )
  end

  def null_logger
    HuggingFaceStorage::NullLogger.new
  end

  def capture_logger(level: :debug, format: :default)
    output = StringIO.new
    logger = HuggingFaceStorage::HFLogger.new(level: level, output: output, format: format)
    [logger, output]
  end

  def mock_api_response(code, body = nil, headers = {})
    response = instance_double(Net::HTTPResponse,
      code: code.to_s,
      body: body.is_a?(Hash) ? JSON.generate(body) : body
    )
    allow(response).to receive(:[]).and_return(nil)
    headers.each { |k, v| allow(response).to receive(:[]).with(k).and_return(v) }
    allow(response).to receive(:each_header).and_yield("content-type", "application/json")
    response
  end

  BUCKET_ID = "test-user/test-bucket"
  BASE_URL = "https://huggingface.co"
  CAS_URL = "https://cas.huggingface.co"

  def xet_write_token_response
    {
      "casUrl" => CAS_URL,
      "accessToken" => "xet_write_token_abc",
      "exp" => 9999999999
    }
  end

  def xet_read_token_response
    {
      "casUrl" => CAS_URL,
      "accessToken" => "xet_read_token_abc",
      "exp" => 9999999999
    }
  end
end

RSpec.configure do |config|
  config.include TestHelpers
end
