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

    # Initializes the hasher and loads the Blake3 native library.
    def initialize
      init_blake3_lib
      @xorb_tree = XorbHashTree.new
    end

    # Chunks data using content-defined chunking.
    #
    # @param data [String] input binary data
    # @return [Array<Array(Integer, Integer)>] array of [start, end) ranges
    def cdc_chunk(data)
      CdcChunker.new(gearhash_table: GEARHASH_TABLE).cdc_chunk(data)
    end

    # Pure-Ruby implementation of CDC chunking.
    #
    # @param data [String] input binary data
    # @return [Array<Array(Integer, Integer)>] array of [start, end) ranges
    def cdc_chunk_ruby(data)
      CdcChunker.new(gearhash_table: GEARHASH_TABLE).cdc_chunk_ruby(data)
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

    # Computes the xorb hash from a list of chunk hashes and lengths using a Merkle tree.
    #
    # @param chunk_hashes_and_lengths [Array<Array, Hash>] array of [hash, length] pairs
    #   or hashes with :hash/:length keys
    # @return [String] 32-byte xorb hash digest
    def compute_xorb_hash(chunk_hashes_and_lengths)
      return ("\x00" * 32).b if chunk_hashes_and_lengths.empty?

      hashes = chunk_hashes_and_lengths.map do |item|
        item.is_a?(Array) ? item[0] : item[:hash]
      end

      @xorb_tree.build(hashes)
    end

    # Computes the file-level hash from a xorb hash.
    #
    # @param xorb_hash [String] 32-byte xorb hash
    # @return [String] 32-byte file hash digest
    def compute_file_hash(xorb_hash)
      blake3_keyed(ZERO_KEY, xorb_hash)
    end

    # Computes a verification hash from an ordered list of chunk hashes.
    #
    # @param chunk_hashes [Array<String>] array of 32-byte chunk hashes
    # @return [String] 32-byte verification hash digest
    def compute_verification_hash(chunk_hashes)
      combined = chunk_hashes.join.b
      blake3_keyed(VERIFICATION_KEY, combined)
    end

    private

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
  end
end
