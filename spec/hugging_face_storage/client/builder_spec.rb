# frozen_string_literal: true

require "spec_helper"

RSpec.describe HuggingFaceStorage::Client::Builder do
  subject(:builder) { described_class.new(options) }

  let(:options) { {} }

  describe "#initialize" do
    it "merges options with defaults" do
      b = described_class.new(log_level: :debug, debug_mode: true)
      expect(b).to be_a(described_class)
    end

    it "uses default log_level of :info" do
      expect(builder.instance_variable_get(:@options)[:log_level]).to eq(:info)
    end

    it "uses default log_format of :default" do
      expect(builder.instance_variable_get(:@options)[:log_format]).to eq(:default)
    end

    it "uses default log_output of $stdout" do
      expect(builder.instance_variable_get(:@options)[:log_output]).to eq($stdout)
    end

    it "uses default log_color of :auto" do
      expect(builder.instance_variable_get(:@options)[:log_color]).to eq(:auto)
    end

    it "uses default debug_mode of false" do
      expect(builder.instance_variable_get(:@options)[:debug_mode]).to be false
    end
  end

  describe "setters" do
    it "token= overrides constructor value" do
      b = described_class.new(token: "old")
      b.token = "new"
      expect(b.instance_variable_get(:@options)[:token]).to eq("new")
    end

    it "namespace= overrides constructor value" do
      b = described_class.new(namespace: "old")
      b.namespace = "new"
      expect(b.instance_variable_get(:@options)[:namespace]).to eq("new")
    end

    it "bucket= overrides constructor value" do
      b = described_class.new(bucket: "old")
      b.bucket = "new"
      expect(b.instance_variable_get(:@options)[:bucket]).to eq("new")
    end

    it "config= overrides constructor value" do
      cfg1 = instance_double(HuggingFaceStorage::Configuration)
      cfg2 = instance_double(HuggingFaceStorage::Configuration)
      b = described_class.new(config: cfg1)
      b.config = cfg2
      expect(b.instance_variable_get(:@options)[:config]).to be(cfg2)
    end

    it "log_level= overrides constructor value" do
      b = described_class.new(log_level: :info)
      b.log_level = :debug
      expect(b.instance_variable_get(:@options)[:log_level]).to eq(:debug)
    end

    it "log_format= overrides constructor value" do
      b = described_class.new(log_format: :default)
      b.log_format = :json
      expect(b.instance_variable_get(:@options)[:log_format]).to eq(:json)
    end

    it "log_output= overrides constructor value" do
      io = StringIO.new
      b = described_class.new(log_output: $stdout)
      b.log_output = io
      expect(b.instance_variable_get(:@options)[:log_output]).to be(io)
    end

    it "log_color= overrides constructor value" do
      b = described_class.new(log_color: :auto)
      b.log_color = true
      expect(b.instance_variable_get(:@options)[:log_color]).to be true
    end

    it "debug_mode= overrides constructor value" do
      b = described_class.new(debug_mode: false)
      b.debug_mode = true
      expect(b.instance_variable_get(:@options)[:debug_mode]).to be true
    end

    it "metrics_registry= overrides constructor value" do
      r1 = instance_double(HuggingFaceStorage::NullMetricsRegistry)
      r2 = instance_double(HuggingFaceStorage::NullMetricsRegistry)
      b = described_class.new(metrics_registry: r1)
      b.metrics_registry = r2
      expect(b.instance_variable_get(:@options)[:metrics_registry]).to be(r2)
    end

    it "notifications= overrides constructor value" do
      n1 = instance_double(HuggingFaceStorage::NullNotifications)
      n2 = instance_double(HuggingFaceStorage::NullNotifications)
      b = described_class.new(notifications: n1)
      b.notifications = n2
      expect(b.instance_variable_get(:@options)[:notifications]).to be(n2)
    end
  end

  describe "#build" do
    let(:options) { { namespace: "test-user", bucket: "test-bucket", token: "hf_test", log_output: StringIO.new } }

    it "creates a Client instance" do
      expect(builder.build).to be_a(HuggingFaceStorage::Client)
    end

    it "wires FileManager" do
      expect(builder.build.files).to be_a(HuggingFaceStorage::FileManager)
    end

    it "wires DirectoryManager" do
      expect(builder.build.directories).to be_a(HuggingFaceStorage::DirectoryManager)
    end

    it "sets bucket_id to namespace/bucket" do
      expect(builder.build.bucket_id).to eq("test-user/test-bucket")
    end

    it "creates default Configuration when none given" do
      client = builder.build
      expect(client.config).to be_a(HuggingFaceStorage::Configuration)
    end

    it "wires custom config when provided" do
      config = HuggingFaceStorage::Configuration.new
      b = described_class.new(namespace: "u", bucket: "b", token: "t", config: config, log_output: StringIO.new)
      expect(b.build.config).to be(config)
    end

    it "creates HFLogger from log_* options" do
      client = builder.build
      expect(client.logger).to be_a(HuggingFaceStorage::HFLogger)
    end

    it "builds HFLogger with default :info level" do
      client = builder.build
      expect(client.logger.level).to eq(:info)
    end

    it "builds HFLogger with custom log_level" do
      b = described_class.new(namespace: "u", bucket: "b", token: "t", log_level: :debug, log_output: StringIO.new)
      expect(b.build.logger.level).to eq(:debug)
    end

    it "wires XetUploader into FileManager" do
      client = builder.build
      expect(client.files.instance_variable_get(:@xet_uploader)).to be_a(HuggingFaceStorage::XetUploader)
    end

    it "wires XetDownloader into FileManager" do
      client = builder.build
      expect(client.files.instance_variable_get(:@xet_downloader)).to be_a(HuggingFaceStorage::XetDownloader)
    end

    it "accepts custom metrics_registry" do
      registry = HuggingFaceStorage::NullMetricsRegistry.new
      b = described_class.new(namespace: "u", bucket: "b", token: "t",
                              metrics_registry: registry, log_output: StringIO.new)
      client = b.build
      expect(client.instance_variable_get(:@metrics_registry)).to be(registry)
    end

    it "accepts custom notifications" do
      notifications = HuggingFaceStorage::NullNotifications.new
      b = described_class.new(namespace: "u", bucket: "b", token: "t",
                              notifications: notifications, log_output: StringIO.new)
      client = b.build
      expect(client.instance_variable_get(:@notifications)).to be(notifications)
    end
  end

  describe "validation" do
    it "raises ArgumentError when namespace is nil" do
      b = described_class.new(namespace: nil, bucket: "b")
      expect { b.build }.to raise_error(ArgumentError, /namespace/)
    end

    it "raises ArgumentError when namespace is empty" do
      b = described_class.new(namespace: "", bucket: "b")
      expect { b.build }.to raise_error(ArgumentError, /namespace/)
    end

    it "raises ArgumentError when bucket is nil" do
      b = described_class.new(namespace: "u", bucket: nil)
      expect { b.build }.to raise_error(ArgumentError, /bucket/)
    end

    it "raises ArgumentError when bucket is empty" do
      b = described_class.new(namespace: "u", bucket: "")
      expect { b.build }.to raise_error(ArgumentError, /bucket/)
    end
  end

  describe "block-style builder" do
    it "creates a Client via HuggingFaceStorage.build" do
      client = HuggingFaceStorage.build do |b|
        b.token = "hf_test"
        b.namespace = "user"
        b.bucket = "bucket"
        b.log_output = StringIO.new
      end
      expect(client).to be_a(HuggingFaceStorage::Client)
      expect(client.bucket_id).to eq("user/bucket")
    end

    it "supports setting debug_mode via block" do
      client = HuggingFaceStorage.build do |b|
        b.token = "hf_test"
        b.namespace = "u"
        b.bucket = "b"
        b.debug_mode = true
        b.log_output = StringIO.new
      end
      expect(client.debug_mode).to be true
    end

    it "supports setting log_level via block" do
      client = HuggingFaceStorage.build do |b|
        b.token = "hf_test"
        b.namespace = "u"
        b.bucket = "b"
        b.log_level = :debug
        b.log_output = StringIO.new
      end
      expect(client.log_level).to eq(:debug)
    end
  end
end
