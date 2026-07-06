# frozen_string_literal: true

require "spec_helper"

RSpec.describe HuggingFaceStorage::TransportConfig do
  let(:dummy_class) do
    Class.new do
      include HuggingFaceStorage::TransportConfig

      attr_reader :http_pool, :retryable, :transport

      def initialize(config, logger)
        @config = config
        @logger = logger
      end
    end
  end

  let(:config) { HuggingFaceStorage::Configuration.new }
  let(:logger) { HuggingFaceStorage::NullLogger.new }
  subject(:instance) { dummy_class.new(config, logger) }

  describe "#init_transport_config!" do
    it "creates HttpPool and Retryable when transport is nil" do
      instance.init_transport_config!(nil)

      expect(instance.http_pool).to be_a(HuggingFaceStorage::HttpPool)
      expect(instance.retryable).to be_a(HuggingFaceStorage::Retryable)
    end

    it "sets transport to nil when nil is passed" do
      instance.init_transport_config!(nil)
      expect(instance.transport).to be_nil
    end

    it "skips pool creation when transport is provided" do
      transport = instance_double(HuggingFaceStorage::HTTPTransport)
      instance.init_transport_config!(transport)

      expect(instance.transport).to be(transport)
      expect(instance.http_pool).to be_nil
      expect(instance.retryable).to be_nil
    end
  end
end
