# frozen_string_literal: true

require "spec_helper"

RSpec.describe HuggingFaceStorage::DirectoryUploader do
  let(:api) do
    instance_double(HuggingFaceStorage::ApiClient).tap do |a|
      allow(a).to receive(:get_xet_write_token).and_return(
        endpoint: TestHelpers::CAS_URL, token: "xet_write_abc", expiration: 9999999999
      )
      allow(a).to receive(:batch)
      allow(a).to receive(:post).and_return([{ "path" => "test.txt", "size" => 100, "xetHash" => "abc123" }])
    end
  end
  let(:xet_uploader) do
    instance_double(HuggingFaceStorage::XetUploader).tap do |x|
      allow(x).to receive(:upload_batch).and_return([])
      allow(x).to receive(:upload_file_to_path).and_return({ xet_hash: "abc", size: 10 })
    end
  end
  let(:bucket_id) { TestHelpers::BUCKET_ID }
  let(:logger) { null_logger }
  subject(:uploader) do
    described_class.new(api_client: api, xet_uploader: xet_uploader, bucket_id: bucket_id, logger: logger)
  end

  describe "#upload" do
    it "uploads small files in batch" do
      Dir.mktmpdir do |dir|
        File.write(File.join(dir, "a.txt"), "hello")
        result = uploader.upload(dir, "remote")
        expect(result[:files_uploaded]).to eq(1)
        expect(xet_uploader).to have_received(:upload_batch).once
      end
    end

    it "uploads large files individually" do
      Dir.mktmpdir do |dir|
        config = HuggingFaceStorage::Configuration.new(batch_threshold: 1)
        custom = described_class.new(api_client: api, xet_uploader: xet_uploader, bucket_id: bucket_id, logger: logger,
config: config)
        File.write(File.join(dir, "large.bin"), "x" * 100)
        result = custom.upload(dir, "remote")
        expect(result[:files_uploaded]).to eq(1)
        expect(xet_uploader).to have_received(:upload_file_to_path).once
      end
    end

    it "mixes batch and individual uploads" do
      Dir.mktmpdir do |dir|
        config = HuggingFaceStorage::Configuration.new(batch_threshold: 10)
        custom = described_class.new(api_client: api, xet_uploader: xet_uploader, bucket_id: bucket_id, logger: logger,
config: config)
        File.write(File.join(dir, "small.txt"), "small")
        File.write(File.join(dir, "large.bin"), "x" * 100)
        result = custom.upload(dir, "remote")
        expect(result[:files_uploaded]).to eq(2)
        expect(xet_uploader).to have_received(:upload_batch).once
        expect(xet_uploader).to have_received(:upload_file_to_path).once
      end
    end

    it "raises Error when directory is empty" do
      Dir.mktmpdir do |dir|
        expect { uploader.upload(dir, "remote") }
          .to raise_error(HuggingFaceStorage::Error, /No files found/)
      end
    end

    it "calls on_progress via cancel_token check" do
      Dir.mktmpdir do |dir|
        File.write(File.join(dir, "f.txt"), "data")
        token = HuggingFaceStorage::CancelToken.new
        result = uploader.upload(dir, "remote", cancel_token: token)
        expect(result[:files_uploaded]).to eq(1)
      end
    end

    it "invokes batch on_progress callback for small files" do
      Dir.mktmpdir do |dir|
        File.write(File.join(dir, "a.txt"), "hello")

        allow(xet_uploader).to receive(:upload_batch) do |_bid, _entries, **opts|
          opts[:on_progress].call(0, "remote/a.txt", 5) if opts[:on_progress]
          []
        end

        result = uploader.upload(dir, "remote")
        expect(result[:files_uploaded]).to eq(1)
      end
    end

    it "splits small files into multiple batches when total exceeds memory limit" do
      Dir.mktmpdir do |dir|
        config = HuggingFaceStorage::Configuration.new(batch_memory_limit: 10)
        custom_uploader = described_class.new(api_client: api, xet_uploader: xet_uploader, bucket_id: bucket_id, logger: logger,
config: config)
        File.write(File.join(dir, "a.txt"), "hello!")
        File.write(File.join(dir, "b.txt"), "world!")
        File.write(File.join(dir, "c.txt"), "ruby!")
        File.write(File.join(dir, "d.txt"), "data!")

        result = custom_uploader.upload(dir, "remote")
        expect(result[:files_uploaded]).to eq(4)
        expect(xet_uploader).to have_received(:upload_batch).at_least(:twice)
      end
    end

    it "logs progress every 10 files during batch upload" do
      Dir.mktmpdir do |dir|
        (1..11).each { |i| File.write(File.join(dir, "f#{i}.txt"), "data") }

        allow(xet_uploader).to receive(:upload_batch) do |_bid, _entries, **opts|
          handler = opts[:on_progress]
          11.times { |i| handler.call(i, "remote/f#{i + 1}.txt", 4) }
          []
        end

        result = uploader.upload(dir, "remote")
        expect(result[:files_uploaded]).to eq(11)
      end
    end

    it "invokes large file on_progress callback" do
      Dir.mktmpdir do |dir|
        config = HuggingFaceStorage::Configuration.new(batch_threshold: 1)
        custom = described_class.new(api_client: api, xet_uploader: xet_uploader, bucket_id: bucket_id, logger: logger,
config: config)
        File.write(File.join(dir, "large.bin"), "x" * 100)

        allow(xet_uploader).to receive(:upload_file_to_path) do |_bid, _path, _target, **opts|
          opts[:on_progress].call("remote/large.bin", 50, 100) if opts[:on_progress]
          { xet_hash: "abc", size: 100 }
        end

        result = custom.upload(dir, "remote")
        expect(result[:files_uploaded]).to eq(1)
      end
    end

    it "evaluates format string in debug block for large file progress" do
      Dir.mktmpdir do |dir|
        config = HuggingFaceStorage::Configuration.new(batch_threshold: 1)
        block_logger = Class.new do
          attr_reader :debug_messages

          def initialize
            @debug_messages = []
          end

          def debug(&_block)
            @debug_messages << yield
          end

          def info(*_args); end
          def warn(*_args); end
          def error(*_args); end
        end.new
        custom = described_class.new(api_client: api, xet_uploader: xet_uploader, bucket_id: bucket_id, logger: block_logger,
config: config)
        File.write(File.join(dir, "large.bin"), "x" * 100)

        allow(xet_uploader).to receive(:upload_file_to_path) do |_bid, _path, _target, **opts|
          opts[:on_progress].call("remote/large.bin", 50, 100) if opts[:on_progress]
          { xet_hash: "abc", size: 100 }
        end

        result = custom.upload(dir, "remote")
        expect(result[:files_uploaded]).to eq(1)
        expect(block_logger.debug_messages.first).to match(/large\.bin: .*\/.* \(\d+%\)/)
      end
    end
  end
end
