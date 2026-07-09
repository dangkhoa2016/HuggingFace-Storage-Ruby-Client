# frozen_string_literal: true

# Inline stubs for XetHasher dependencies — replaced by real versions in commit 51
module HuggingFaceStorage
  module Blake3Binding
  end

  class CdcChunker
    TARGET_CHUNK = 65_536
    MIN_CHUNK = TARGET_CHUNK / 8
    MAX_CHUNK = TARGET_CHUNK * 2
    MASK = 0xFFFF_0000_0000_0000
  end
end

module HuggingFaceStorage
  # Computes content-defined chunk hashes, xorb hashes, file hashes, and verification hashes.
  class XetHasher
    include Blake3Binding

    XORB_MAX_SIZE = 64 * 1024 * 1024
    XORB_MAX_CHUNKS = 8 * 1024
    MEAN_CHUNK_PER_NODE = 4
    CHUNK_HEADER_SIZE = 8
    IDX_LAST_U64_BYTE = 3 * 8
    BATCH_PARALLEL_THRESHOLD = 4
    THREAD_POOL_KEY = :hugging_face_storage_blake3_pool

    MASK = CdcChunker::MASK
    MIN_CHUNK = CdcChunker::MIN_CHUNK
    MAX_CHUNK = CdcChunker::MAX_CHUNK
    TARGET_CHUNK = CdcChunker::TARGET_CHUNK

    def initialize
      init_blake3_lib
      @mutex = Mutex.new
      @gearhash_table = GearhashTable.new
    end

    def init_blake3_lib
      require "blake3_native"
    rescue LoadError
      warn "Blake3 native extension not available, Xet operations disabled"
    end

    def chunk_data(data, offset = 0)
      CdcChunker.new(data, offset).chunks
    end

    def compute_chunk_hashes(chunks)
      chunks.map { |chunk| blake3_hash(chunk) }
    end

    def compute_xorb_hash(chunk_hashes)
      XorbHashTree.new(chunk_hashes).root_hash
    end

    def compute_file_hash(data)
      blake3_hash(data)
    end

    def compute_verification_hash(chunk_hashes)
      blake3_hash(chunk_hashes.join)
    end

    def blake3_hash(data)
      Blake3Pool.hash(data)
    end
  end
end
