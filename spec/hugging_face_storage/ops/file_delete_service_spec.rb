# frozen_string_literal: true

require "spec_helper"

RSpec.describe HuggingFaceStorage::FileDeleteService do
  let(:bucket_id) { TestHelpers::BUCKET_ID }
  let(:logger) { null_logger }
  let(:config) { HuggingFaceStorage::Configuration.default }
  let(:api) do
    instance_double(HuggingFaceStorage::ApiClient).tap do |a|
      allow(a).to receive(:post).and_return(nil)
      allow(a).to receive(:batch).and_return(HuggingFaceStorage::BatchResult.new)
    end
  end

  subject(:service) { described_class.new(api_client: api, bucket_id: bucket_id, config: config, logger: logger) }

  describe "#delete" do
    it "deletes a single file and returns true" do
      allow(api).to receive(:post)
        .with("/api/buckets/#{bucket_id}/paths-info", hash_including(body: { paths: ["old.txt"] }))
        .and_return([{ "type" => "file", "path" => "old.txt", "size" => 10, "xetHash" => "x" }])

      result = service.delete("old.txt")
      expect(result).to be true
      expect(api).to have_received(:batch).with(bucket_id, [{ type: "deleteFile", path: "old.txt" }],
        hash_including(cancel_token: nil, raise_on_partial_failure: true))
    end

    it "deletes multiple files and returns BatchResult" do
      allow(api).to receive(:post)
        .with("/api/buckets/#{bucket_id}/paths-info", hash_including(body: { paths: ["a.txt", "b.txt"] }))
        .and_return([
          { "type" => "file", "path" => "a.txt", "size" => 10, "xetHash" => "x" },
          { "type" => "file", "path" => "b.txt", "size" => 20, "xetHash" => "y" }
        ])

      result = service.delete(["a.txt", "b.txt"])
      expect(result).to be_a(HuggingFaceStorage::BatchResult)
      expect(api).to have_received(:batch).with(bucket_id, [
        { type: "deleteFile", path: "a.txt" },
        { type: "deleteFile", path: "b.txt" }
      ], hash_including(cancel_token: nil))
    end

    it "strips leading slashes from paths" do
      allow(api).to receive(:post)
        .with("/api/buckets/#{bucket_id}/paths-info", hash_including(body: { paths: ["file.txt"] }))
        .and_return([{ "type" => "file", "path" => "file.txt", "size" => 10, "xetHash" => "x" }])

      service.delete("/file.txt")
      expect(api).to have_received(:batch).with(bucket_id, [{ type: "deleteFile", path: "file.txt" }],
        hash_including(cancel_token: nil))
    end

    it "splits into batches based on config.delete_batch_size" do
      custom_config = HuggingFaceStorage::Configuration.new(batch: HuggingFaceStorage::Configuration::BatchConfig.new(
        delete_batch_size: 2
      ))
      svc = described_class.new(api_client: api, bucket_id: bucket_id, config: custom_config, logger: logger)

      paths = %w[a.txt b.txt c.txt]
      allow(api).to receive(:post).with(/paths-info/, anything) { |_, body:|
        body[:paths].map { |p| { "type" => "file", "path" => p, "size" => 1, "xetHash" => "h" } }
      }
      batch_calls = []
      allow(api).to receive(:batch) do |_, ops, **|
        batch_calls << ops
        HuggingFaceStorage::BatchResult.new
      end

      svc.delete(paths)
      expect(batch_calls.size).to eq(2)
      expect(batch_calls[0].size).to eq(2)
      expect(batch_calls[1].size).to eq(1)
    end

    it "raises NotFoundError when file does not exist" do
      allow(api).to receive(:post)
        .with("/api/buckets/#{bucket_id}/paths-info", hash_including(body: { paths: ["ghost.txt"] }))
        .and_return([])

      expect { service.delete("ghost.txt") }
        .to raise_error(HuggingFaceStorage::NotFoundError)
    end

    it "raises Error when path is a directory" do
      allow(api).to receive(:post)
        .with("/api/buckets/#{bucket_id}/paths-info", hash_including(body: { paths: ["models"] }))
        .and_return([{ "type" => "directory", "path" => "models" }])

      expect { service.delete("models") }
        .to raise_error(HuggingFaceStorage::Error, /Use client.directories.delete instead/)
    end

    it "raises Error when any path in array is a directory" do
      allow(api).to receive(:post)
        .with("/api/buckets/#{bucket_id}/paths-info", hash_including(body: { paths: ["a.txt", "models", "b.txt"] }))
        .and_return([
          { "type" => "file", "path" => "a.txt", "size" => 10, "xetHash" => "x" },
          { "type" => "directory", "path" => "models" },
          { "type" => "file", "path" => "b.txt", "size" => 20, "xetHash" => "y" }
        ])

      expect { service.delete(["a.txt", "models", "b.txt"]) }
        .to raise_error(HuggingFaceStorage::Error, /Use client.directories.delete instead/)
    end

    it "checks cancel_token before each batch" do
      allow(api).to receive(:post).with(/paths-info/, anything) { |_, body:|
        body[:paths].map { |p| { "type" => "file", "path" => p, "size" => 1, "xetHash" => "h" } }
      }

      cancel_token = instance_double(HuggingFaceStorage::CancelToken)
      allow(cancel_token).to receive(:raise_if_cancelled!)

      small_config = HuggingFaceStorage::Configuration.new(batch: HuggingFaceStorage::Configuration::BatchConfig.new(
        delete_batch_size: 2
      ))
      svc = described_class.new(api_client: api, bucket_id: bucket_id, config: small_config, logger: logger)

      allow(api).to receive(:batch).and_return(HuggingFaceStorage::BatchResult.new)
      svc.delete(%w[a.txt b.txt c.txt], cancel_token: cancel_token)
      expect(cancel_token).to have_received(:raise_if_cancelled!).at_least(:once)
    end

    it "raises CancelledError when cancelled before batch" do
      allow(api).to receive(:post).with(/paths-info/, anything) { |_, body:|
        body[:paths].map { |p| { "type" => "file", "path" => p, "size" => 1, "xetHash" => "h" } }
      }

      cancel_token = instance_double(HuggingFaceStorage::CancelToken)
      allow(cancel_token).to receive(:raise_if_cancelled!).and_raise(HuggingFaceStorage::CancelledError)

      expect { service.delete("file.txt", cancel_token: cancel_token) }
        .to raise_error(HuggingFaceStorage::CancelledError)
    end

    it "forwards raise_on_partial_failure to api.batch" do
      allow(api).to receive(:post).with(/paths-info/, anything) { |_, body:|
        body[:paths].map { |p| { "type" => "file", "path" => p, "size" => 1, "xetHash" => "h" } }
      }

      service.delete("file.txt", raise_on_partial_failure: false)
      expect(api).to have_received(:batch).with(bucket_id, anything,
        hash_including(raise_on_partial_failure: false))
    end
  end
end
