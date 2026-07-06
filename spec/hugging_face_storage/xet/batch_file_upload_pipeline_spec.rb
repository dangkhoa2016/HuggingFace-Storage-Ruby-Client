# frozen_string_literal: true

require "spec_helper"

RSpec.describe HuggingFaceStorage::BatchFileUploadPipeline do
  subject(:pipeline) do
    described_class.new(
      hasher: hasher, api_client: api_client, token_manager: token_manager,
      config: config, logger: logger, http_pool: http_pool, retryable: retryable
    )
  end

  let(:hasher) { instance_double(HuggingFaceStorage::XetHasher) }
  let(:api_client) { instance_double(HuggingFaceStorage::ApiClient) }
  let(:token_manager) { instance_double(HuggingFaceStorage::XetTokenManager) }
  let(:config) { HuggingFaceStorage::Configuration.new(retry_delay: 0.001) }
  let(:logger) { instance_double(HuggingFaceStorage::HFLogger, debug: nil, info: nil, warn: nil, error: nil) }
  let(:http_pool) { instance_double(HuggingFaceStorage::HttpPool) }
  let(:retryable) { instance_double(HuggingFaceStorage::Retryable) }
  let(:bucket_id) { TestHelpers::BUCKET_ID }
  let(:cas_url) { TestHelpers::CAS_URL }
  let(:cancel_token) { HuggingFaceStorage::CancelToken.new }

  let(:state) do
    HuggingFaceStorage::XetDataUploader::XorbBatchState.new(
      all_chunk_metas: [], uploaded_xorbs: [], file_metas: [],
      pending_chunks: [], pending_size: 0, global_chunk_idx: 0
    )
  end

  let(:chunk_hash) { ("\x01" * 32).b }
  let(:xorb_hash) { ("\x02" * 32).b }
  let(:file_hash) { ("\x03" * 32).b }

  let(:chunk_header_size) { HuggingFaceStorage::XetHasher::CHUNK_HEADER_SIZE }
  let(:xorb_max_size) { HuggingFaceStorage::XetHasher::XORB_MAX_SIZE }
  let(:xorb_max_chunks) { HuggingFaceStorage::XetHasher::XORB_MAX_CHUNKS }

  before do
    allow(logger).to receive(:debug)
    allow(hasher).to receive(:compute_xorb_hash).and_return(xorb_hash)
    allow(hasher).to receive(:compute_file_hash).and_return(file_hash)
    allow(token_manager).to receive(:fetch_write_token).with(bucket_id).and_return(
      endpoint: TestHelpers::CAS_URL, token: "xet_write_token_abc", expiration: 9_999_999_999
    )

    http_resp = instance_double(Net::HTTPResponse, code: "200", body: "")
    allow(http_resp).to receive(:[]).and_return(nil)
    http_double = double("http")
    allow(http_double).to receive(:request).and_return(http_resp)
    allow(http_pool).to receive(:with_connection).and_yield(http_double).and_return(http_resp)
    allow(retryable).to receive(:retry_with_backoff).and_yield(0).and_return(http_resp)
  end

  describe "#process_file_chunks" do
    let(:chunk_data) { "a" * 100 }
    let(:chunk_length) { 100 }

    it "accumulates chunks into pending state" do
      chunk_count = pipeline.process_file_chunks(
        bucket_id, cas_url, state, [chunk_data], [chunk_hash], [chunk_length], cancel_token
      )

      expect(chunk_count).to eq(1)
      expect(state.pending_chunks.size).to eq(1)
      expect(state.pending_size).to eq(chunk_header_size + 100)
      expect(state.global_chunk_idx).to eq(1)
    end

    it "flushes pending chunks when xorb max chunks is exceeded" do
      many_chunks = (xorb_max_chunks + 1).times.map { "x" * 100 }
      many_hashes = (xorb_max_chunks + 1).times.map { chunk_hash }
      many_lengths = (xorb_max_chunks + 1).times.map { 100 }

      pipeline.process_file_chunks(
        bucket_id, cas_url, state, many_chunks, many_hashes, many_lengths, cancel_token
      )

      expect(state.uploaded_xorbs.size).to eq(1)
    end
  end

  describe "#flush_pending_xorb" do
    before do
      state.pending_chunks << { data: "test", hash: chunk_hash, length: 4 }
      state.pending_size = chunk_header_size + 4
    end

    it "uploads pending chunks as a xorb" do
      pipeline.flush_pending_xorb(bucket_id, cas_url, state, cancel_token: cancel_token)

      expect(state.uploaded_xorbs.size).to eq(1)
      expect(state.pending_chunks).to be_empty
      expect(state.pending_size).to eq(0)
    end

    it "does nothing when no pending chunks" do
      empty_state = HuggingFaceStorage::XetDataUploader::XorbBatchState.new(
        all_chunk_metas: [], uploaded_xorbs: [], file_metas: [],
        pending_chunks: [], pending_size: 0, global_chunk_idx: 0
      )

      pipeline.flush_pending_xorb(bucket_id, cas_url, empty_state, cancel_token: cancel_token)

      expect(empty_state.uploaded_xorbs).to be_empty
    end
  end

  describe "#process_single_file_entry" do
    let(:entry) { { local_path: "/tmp/test.bin", remote_path: "remote/test.bin", size: 100 } }

    before do
      allow(File).to receive(:binread).with("/tmp/test.bin").and_return("x" * 100)
    end

    it "processes a file entry and adds file meta" do
      pipeline.process_single_file_entry(bucket_id, cas_url, state, entry, 0, nil, cancel_token) do |e, cancel_token:|
        [["chunk_data"], [chunk_hash], [100], [{ hash: chunk_hash, length: 100 }]]
      end

      expect(state.file_metas.size).to eq(1)
      expect(state.file_metas[0][:remote_path]).to eq("remote/test.bin")
    end

    it "raises CancelledError when token is cancelled" do
      cancel_token.cancel!

      expect do
        pipeline.process_single_file_entry(bucket_id, cas_url, state, entry, 0, nil, cancel_token) do |e, cancel_token:|
          [["chunk_data"], [chunk_hash], [100], []]
        end
      end.to raise_error(HuggingFaceStorage::CancelledError)
    end
  end

  describe "#process_file_entries" do
    let(:entries) do
      [
        { local_path: "/tmp/a.bin", remote_path: "remote/a.bin", size: 100 },
        { local_path: "/tmp/b.bin", remote_path: "remote/b.bin", size: 200 }
      ]
    end

    before do
      allow(File).to receive(:binread).and_return("x" * 100)
    end

    it "processes all file entries" do
      pipeline.process_file_entries(bucket_id, cas_url, state, entries,
cancel_token: cancel_token) do |e, cancel_token:|
        [["chunk_data"], [chunk_hash], [e[:size]], [{ hash: chunk_hash, length: e[:size] }]]
      end

      expect(state.file_metas.size).to eq(2)
    end
  end
end
