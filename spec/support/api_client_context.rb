# frozen_string_literal: true

RSpec.shared_context "with api client setup" do
  let(:auth) { HuggingFaceStorage::Authentication.new(token: "hf_test_token") }
  let(:logger) { null_logger }
  let(:fast_config) { HuggingFaceStorage::Configuration.new(retry_delay: 0.001, max_retry_delay: 0.05) }
  let(:client) { described_class.new(auth: auth, logger: logger, config: fast_config) }
  let(:base) { "https://huggingface.co" }
  let(:bucket_id) { "test-user/test-bucket" }
end
