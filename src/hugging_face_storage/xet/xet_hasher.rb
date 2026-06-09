# frozen_string_literal: true

require_relative "blake3_binding"
require_relative "cdc_chunker"
require_relative "blake3_pool"
require_relative "xorb_hash_tree"

module HuggingFaceStorage
  # Computes content-defined chunk hashes, xorb hashes, file hashes, and verification hashes.
  class XetHasher
    include Blake3Binding

    # Maximum serialized xorb size in bytes (64 MiB).
    XORB_MAX_SIZE = 64 * 1024 * 1024
    # Maximum number of chunks per xorb.
    XORB_MAX_CHUNKS = 8 * 1024
    # Mean number of chunks per hash tree node.
    MEAN_CHUNK_PER_NODE = 4
    # Size of each chunk header in bytes.
    CHUNK_HEADER_SIZE = 8
    # Byte offset of the last u64 in the hash tree index.
    IDX_LAST_U64_BYTE = 3 * 8
    # Minimum number of items to enable parallel batch hashing.
    BATCH_PARALLEL_THRESHOLD = 4

    # Minimum total data size in bytes to enable parallel hashing.
    # Below this threshold, sequential hashing is faster due to thread dispatch overhead.
    # Benchmark shows sequential 1782 MB/s > batch-4t 840 MB/s for typical 65KB chunks.
    BATCH_PARALLEL_MIN_SIZE = 256 * 1024 # 256 KB

    # Thread-local storage key for the Blake3 thread pool.
    THREAD_POOL_KEY = :hugging_face_storage_blake3_pool

    # Gear-hash mask for chunk boundary detection.
    MASK = CdcChunker::MASK
    # Minimum chunk size in bytes.
    MIN_CHUNK = CdcChunker::MIN_CHUNK
    # Maximum chunk size in bytes.
    MAX_CHUNK = CdcChunker::MAX_CHUNK
    # Target chunk size in bytes.
    TARGET_CHUNK = CdcChunker::TARGET_CHUNK

    # Initializes the hasher and loads native extensions (BLAKE3, Gearhash).
    def initialize
      init_blake3_lib
      self.class.native_available?
      @xorb_tree = XorbHashTree.new
    end

    # Chunks data using content-defined chunking.
    #
    # @param data [String] input binary data
    # @return [Array<Array(Integer, Integer)>] array of [start, end) ranges
    def cdc_chunk(data)
      cdc_chunker.cdc_chunk(data)
    end

    # Performs CDC chunking and BLAKE3 hashing in a single C call.
    # Combines scan_boundaries + blake3_hash_chunk loops into one pass.
    #
    # @param data [String] input binary data
    # @return [Array(Array, String)] tuple of [chunk_ranges, concatenated_hashes]
    #   chunk_ranges: Array[[Integer, Integer]] array of [start, end) ranges
    #   concatenated_hashes: String containing num_chunks × 32 bytes of BLAKE3 hashes
    def cdc_and_hash_native(data)
      if defined?(HuggingFaceStorage::Gearhash) && HuggingFaceStorage::Gearhash.respond_to?(:cdc_and_hash)
        ranges, hashes = HuggingFaceStorage::Gearhash.cdc_and_hash(
          data, GEARHASH_TABLE, DATA_KEY, MASK, MIN_CHUNK, MAX_CHUNK
        )
        [ranges, hashes.b.freeze]
      else
        ranges = cdc_chunk(data)
        hashes = sequential_blake3_from_ranges(DATA_KEY, data, ranges).join.b.freeze
        [ranges, hashes]
      end
    end

    # Performs full pipeline in a single C call: CDC + parallel BLAKE3 (pthread) + xorb serialization.
    # Returns all data needed for shard building without intermediate Ruby allocations.
    #
    # @param data [String] input binary data
    # @return [Array(String, Array, String)] tuple of [hashes_concat, ranges, xorb_data]
    #   hashes_concat: String containing num_chunks × 32 bytes of BLAKE3 hashes
    #   ranges: Array[[Integer, Integer]] array of [start, end) ranges
    #   xorb_data: String with serialized xorb payload
    def full_pipeline_native(data)
      if defined?(HuggingFaceStorage::Gearhash) && HuggingFaceStorage::Gearhash.respond_to?(:full_pipeline)
        HuggingFaceStorage::Gearhash.full_pipeline(
          data, GEARHASH_TABLE, DATA_KEY, MASK, MIN_CHUNK, MAX_CHUNK
        )
      else
        chunk_ranges = cdc_chunk(data)
        hashes_concat = sequential_blake3_from_ranges(DATA_KEY, data, chunk_ranges).join.b.freeze
        xorb_data = HuggingFaceStorage::Gearhash.serialize_xorb_from_ranges(data, chunk_ranges)
        [hashes_concat, chunk_ranges, xorb_data]
      end
    end

    # Pure-Ruby implementation of CDC chunking.
    #
    # @param data [String] input binary data
    # @return [Array<Array(Integer, Integer)>] array of [start, end) ranges
    def cdc_chunk_ruby(data)
      cdc_chunker.cdc_chunk_ruby(data)
    end

    # Computes one step of the gear hash rolling hash.
    #
    # @param state [Integer] current hash state
    # @param byte [Integer] next byte value
    # @return [Integer] updated hash state
    def self.gearhash_step(state, byte)
      CdcChunker.gearhash_step(state, byte)
    end

    # Computes BLAKE3 keyed hashes for an array of data chunks in parallel.
    #
    # @param key [String] the BLAKE3 key
    # @param data_array [Array<String>] array of binary data strings
    # @param num_threads [Integer] maximum number of parallel threads
    # @param cancel_token [CancelToken, nil] cooperative cancellation token
    # @return [Array<String>] array of 32-byte hash digests
    def batch_blake3_keyed(key, data_array, num_threads: 4, cancel_token: nil)
      cancel_token&.raise_if_cancelled!
      return data_array.map { |d| blake3_keyed(key, d) } if data_array.size <= 1 || num_threads <= 1
      return data_array.map { |d| blake3_keyed(key, d) } if data_array.size < BATCH_PARALLEL_THRESHOLD

      actual = [num_threads, data_array.size].min
      pool = thread_local_pool(actual)
      pool.map(data_array, key, cancel_token: cancel_token)
    rescue CancelledError
      shutdown_pool
      raise
    end

    # Computes BLAKE3 keyed hashes directly from source buffer using ranges.
    # Avoids per-chunk String allocation by hashing from pointer offsets.
    #
    # @param key [String] the BLAKE3 key
    # @param data [String] the source binary data
    # @param ranges [Array<Array(Integer, Integer)>] array of [start, end) ranges
    # @param num_threads [Integer] maximum number of parallel threads
    # @param cancel_token [CancelToken, nil] cooperative cancellation token
    # @return [Array<String>] array of 32-byte hash digests
    def batch_blake3_keyed_from_ranges(key, data, ranges, num_threads: 4, cancel_token: nil)
      cancel_token&.raise_if_cancelled!

      return sequential_blake3_from_ranges(key, data, ranges) if should_use_sequential?(ranges, num_threads)

      actual = [num_threads, ranges.size].min
      pool = thread_local_pool(actual)

      # Zero-copy: pass source buffer and ranges directly to workers
      pool.map_from_buffer(key, data, ranges, cancel_token: cancel_token)
    rescue CancelledError
      shutdown_pool
      raise
    end

    # Shuts down all thread-local Blake3 thread pools.
    #
    # @return [void]
    def shutdown_pool
      Thread.list.each do |thread|
        pool = thread[THREAD_POOL_KEY]
        next unless pool

        pool.shutdown
        thread[THREAD_POOL_KEY] = nil
      end
    end

    # Computes the xorb hash from chunk hashes using a Merkle tree.
    #
    # Accepts multiple formats for backward compatibility:
    # - Two parallel arrays (hashes, lengths) — preferred, avoids Hash allocation
    # - Array of [hash, length] tuples (used by batch upload pipeline flush)
    # - Array of Hash with :hash/:length keys (legacy, used by single-file upload)
    #
    # @param chunk_hashes [Array<String>] array of 32-byte chunk hashes (parallel array form)
    # @param chunk_lengths [Array<Integer>, nil] array of chunk lengths (parallel array form, optional)
    # @param chunk_hashes_and_lengths [Array<Array(String, Integer)>, Array<Hash>] chunk metadata (legacy forms)
    # @return [String] 32-byte xorb hash digest
    def compute_xorb_hash(chunk_hashes, chunk_lengths = nil)
      return ("\x00" * 32).b if chunk_hashes.empty?

      hashes = if chunk_lengths
                 chunk_hashes # Already parallel arrays — use directly
               elsif chunk_hashes.first.is_a?(Array)
                 chunk_hashes.map(&:first)
               else
                 chunk_hashes.map { |item| item[:hash] }
               end

      @xorb_tree.build(hashes, validate: false) # Trusted internal input
    end

    # Computes the file-level hash from a xorb hash.
    #
    # @param xorb_hash [String] 32-byte xorb hash
    # @return [String] 32-byte file hash digest
    def compute_file_hash(xorb_hash)
      blake3_keyed(ZERO_KEY, xorb_hash)
    end

    # Computes a verification hash from an ordered list of chunk hashes.
    # Uses incremental Blake3 to avoid allocating a concatenated string.
    #
    # @param chunk_hashes [Array<String>] array of 32-byte chunk hashes
    # @return [String] 32-byte verification hash digest
    def compute_verification_hash(chunk_hashes)
      blake3_keyed_incremental(VERIFICATION_KEY, chunk_hashes)
    end

    private

    def cdc_chunker
      @cdc_chunker ||= CdcChunker.new(gearhash_table: GEARHASH_TABLE)
    end

    # Returns or creates a thread-local Blake3 thread pool of the given size.
    #
    # @param size [Integer] number of worker threads
    # @return [Blake3Pool] the thread-local pool
    def thread_local_pool(size)
      pool = Thread.current[THREAD_POOL_KEY]
      return pool if pool && pool.size == size

      pool&.shutdown
      pool = Blake3Pool.new(self, size)
      Thread.current[THREAD_POOL_KEY] = pool
      pool
    end

    # Determines whether sequential hashing should be used instead of parallel.
    # Sequential is faster when: single range, single thread, few items, or small data.
    #
    # @param ranges [Array<Array(Integer, Integer)>] chunk ranges
    # @param num_threads [Integer] requested thread count
    # @return [Boolean] true if sequential path should be used
    def should_use_sequential?(ranges, num_threads)
      return true if ranges.size <= 1
      return true if num_threads <= 1
      return true if ranges.size < BATCH_PARALLEL_THRESHOLD

      # Auto-disable: skip thread pool for small data where dispatch overhead > hashing time
      total_size = ranges.sum { |pair| pair[1] - pair[0] }
      total_size < BATCH_PARALLEL_MIN_SIZE
    end

    # Computes BLAKE3 hashes sequentially from source buffer ranges.
    #
    # @param key [String] the BLAKE3 key
    # @param data [String] the source binary data
    # @param ranges [Array<Array(Integer, Integer)>] array of [start, end) ranges
    # @return [Array<String>] array of 32-byte hash digests
    def sequential_blake3_from_ranges(key, data, ranges)
      ranges.map { |s, e| blake3_keyed(key, data.byteslice(s, e - s)) }
    end
  end
end
