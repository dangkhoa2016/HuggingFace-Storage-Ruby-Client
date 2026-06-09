# frozen_string_literal: true

require "fiddle"

module HuggingFaceStorage
  # Manages FFI memory buffers for BLAKE3 hashing operations.
  # @api private
  # :nodoc:
  class Blake3Buffers
    # @return [Fiddle::Pointer] the hasher buffer
    # @return [Fiddle::Pointer] the output buffer
    attr_reader :hasher_buf, :out_buf

    # Allocates hasher and output buffers.
    #
    # Buffers are explicitly freed via {#free} when the owning thread exits.
    #
    # @return [Blake3Buffers] the new buffer instance
    def initialize
      @hasher_buf = Fiddle::Pointer.malloc(Blake3Binding::HASHER_SIZE)
      @out_buf = Fiddle::Pointer.malloc(Blake3Binding::OUT_LEN)
    end

    # Frees both the hasher and output buffers.
    #
    # Safe to call multiple times — subsequent calls are no-ops.
    #
    # @return [void]
    def free
      return if @hasher_buf.nil?

      @hasher_buf.free
      @out_buf.free
      @hasher_buf = nil
      @out_buf = nil
    end
  end

  # Native BLAKE3 hash bindings via Fiddle.
  # @api private
  # :nodoc:
  module Blake3Binding
    # Size of the BLAKE3 hasher struct in bytes.
    HASHER_SIZE = 2048
    # Size of BLAKE3 output hash in bytes.
    OUT_LEN = 32

    # BLAKE3 key for hashing chunk data.
    DATA_KEY = [
      0x66, 0x97, 0xf5, 0x77, 0x5b, 0x95, 0x50, 0xde,
      0x31, 0x35, 0xcb, 0xac, 0xa5, 0x97, 0x18, 0x1c,
      0x9d, 0xe4, 0x21, 0x10, 0x9b, 0xeb, 0x2b, 0x58,
      0xb4, 0xd0, 0xb0, 0x4b, 0x93, 0xad, 0xf2, 0x29
    ].pack("C*")

    # BLAKE3 key for hashing hash tree nodes.
    NODE_KEY = [
      0x01, 0x7e, 0xc5, 0xc7, 0xa5, 0x47, 0x29, 0x96,
      0xfd, 0x94, 0x66, 0x66, 0xb4, 0x8a, 0x02, 0xe6,
      0x5d, 0xdd, 0x53, 0x6f, 0x37, 0xc7, 0x6d, 0xd2,
      0xf8, 0x63, 0x52, 0xe6, 0x4a, 0x53, 0x71, 0x3f
    ].pack("C*")

    # BLAKE3 key for computing verification hashes.
    VERIFICATION_KEY = [
      0x7f, 0x18, 0x57, 0xd6, 0xce, 0x56, 0xed, 0x66,
      0x12, 0x7f, 0xf9, 0x13, 0xe7, 0xa5, 0xc3, 0xf3,
      0xa4, 0xcd, 0x26, 0xd5, 0xb5, 0xdb, 0x49, 0xe6,
      0x41, 0x24, 0x98, 0x7f, 0x28, 0xfb, 0x94, 0xc3
    ].pack("C*")

    # All-zero BLAKE3 key (32 bytes).
    ZERO_KEY = ("\x00" * 32).b

    # Thread-local storage key for BLAKE3 hash buffers.
    THREAD_STORAGE_KEY = :hugging_face_storage_blake3_buffers

    # Class methods extended onto Blake3Binding.
    module ClassMethods
      # Locates the blake3 shared library path.
      #
      # @return [String] path to blake3.so
      # @raise [Error] if the gem is not found
      def find_blake3_so
        @find_blake3_so ||= begin
          candidates = Gem.find_files("digest/blake3/blake3.so")

          if candidates.empty?
            so = find_gem_blake3_so
            candidates << so if so
          end

          if candidates.empty?
            [Gem.user_dir, Gem.dir].each do |root|
              Dir.glob(File.join(root, "gems", "digest-blake3-*", "lib", "digest", "blake3",
                                 "blake3.so")).each { |p| candidates << p }
            end
          end

          if candidates.empty?
            arch = File.join(RbConfig::CONFIG["sitearchdir"], "digest", "blake3", "blake3.so")
            candidates << arch if File.exist?(arch)
          end

          path = candidates.find { |p| File.exist?(p) }
          raise Error, "digest-blake3 gem not found. Install: gem install digest-blake3" unless path

          path
        end
      end

      # Returns whether the native BLAKE3 extension is available.
      #
      # @return [Boolean] true if native extension loaded
      def native_available?
        @native_available ||= _load_native
      end

      # Attempts to find the blake3 shared library via gem specification.
      #
      # @return [String, nil] path to blake3.so if found
      def find_gem_blake3_so
        spec = Gem::Specification.find_by_name("digest-blake3")
        so = File.join(spec.gem_dir, "lib", "digest", "blake3", "blake3.so")
        so if File.exist?(so)
      rescue Gem::MissingSpecError
        nil
      end

      # Attempts to load the native gearhash extension.
      # Searches standard gem paths, sitearchdir, and the src/ development tree.
      #
      # @return [Boolean] true if loaded successfully
      def _load_native
        # Standard require path (gem install layout)
        require "hugging_face_storage/gearhash"
        true
      rescue LoadError
        _load_native_from_src
      end

      # Loads gearhash.so from the src/ development tree.
      # Adds src/ to $LOAD_PATH temporarily, then removes it to avoid pollution.
      #
      # @return [Boolean] true if loaded successfully
      def _load_native_from_src
        dir = __dir__
        return false unless dir

        base = File.expand_path("../../../src", dir)
        gearhash_so = File.join(base, "hugging_face_storage", "gearhash.so")
        return false unless File.exist?(gearhash_so)

        $LOAD_PATH.unshift(base)
        require "hugging_face_storage/gearhash"
        true
      rescue LoadError
        false
      ensure
        $LOAD_PATH.delete(base) if base
      end
    end

    extend ClassMethods

    # Extends the including class with ClassMethods.
    #
    # @param base [Class] the including class
    # @return [void]
    def self.included(base)
      base.extend(ClassMethods)
    end

    # Computes a BLAKE3 keyed hash.
    #
    # @param key [String] the 32-byte key
    # @param data [String] the input data
    # @return [String] the 32-byte hash
    def blake3_keyed(key, data)
      buffers = thread_local_buffers
      blake3_keyed_with_buffers(buffers, key, data)
    end

    # Computes a BLAKE3 keyed hash using pre-allocated buffers.
    #
    # @param buffers [Blake3Buffers] pre-allocated buffers
    # @param key [String] the 32-byte key
    # @param data [String] the input data
    # @return [String] the 32-byte hash
    def blake3_keyed_with_buffers(buffers, key, data)
      @b3_init_keyed.call(buffers.hasher_buf, key)
      @b3_update.call(buffers.hasher_buf, data, data.bytesize)
      @b3_finalize.call(buffers.hasher_buf, buffers.out_buf, self.class::OUT_LEN)
      buffers.out_buf.to_str(self.class::OUT_LEN).b.freeze
    end

    # Computes a BLAKE3 keyed hash directly from a source buffer at offset.
    # Zero-copy: no intermediate String allocation for the chunk.
    #
    # @param buffers [Blake3Buffers] pre-allocated buffers
    # @param key [String] the 32-byte key
    # @param source [String] the source data buffer
    # @param offset [Integer] byte offset into source
    # @param length [Integer] number of bytes to hash
    # @return [String] the 32-byte hash
    def blake3_keyed_from_buffer(buffers, key, source, offset, length)
      @b3_init_keyed.call(buffers.hasher_buf, key)
      # Get pointer to source data and add offset
      source_ptr = Fiddle::Pointer[source]
      chunk_ptr = source_ptr + offset
      @b3_update.call(buffers.hasher_buf, chunk_ptr, length)
      @b3_finalize.call(buffers.hasher_buf, buffers.out_buf, self.class::OUT_LEN)
      buffers.out_buf.to_str(self.class::OUT_LEN).b.freeze
    end

    # Computes a BLAKE3 keyed hash incrementally from multiple data chunks.
    # Avoids allocating a single concatenated string — feeds chunks one by one.
    #
    # @param key [String] the 32-byte key
    # @param data_chunks [Array<String>] array of binary data chunks
    # @return [String] the 32-byte hash digest (frozen)
    def blake3_keyed_incremental(key, data_chunks)
      buffers = thread_local_buffers
      @b3_init_keyed.call(buffers.hasher_buf, key)
      data_chunks.each do |chunk|
        @b3_update.call(buffers.hasher_buf, chunk, chunk.bytesize)
      end
      @b3_finalize.call(buffers.hasher_buf, buffers.out_buf, self.class::OUT_LEN)
      buffers.out_buf.to_str(self.class::OUT_LEN).b.freeze
    end

    # Batch hash multiple chunks from a single source buffer using zero-copy.
    # Each chunk is defined by (offset, length) in the ranges array.
    #
    # @param key [String] the 32-byte key
    # @param source [String] the source data buffer
    # @param ranges [Array<Array(Integer, Integer)>] array of [start, end) ranges
    # @return [Array<String>] array of 32-byte hash digests
    def blake3_batch_from_buffer(key, source, ranges)
      buffers = thread_local_buffers
      source_ptr = Fiddle::Pointer[source]
      ranges.map do |range|
        start_pos = range[0]
        end_pos = range[1]
        length = end_pos - start_pos
        @b3_init_keyed.call(buffers.hasher_buf, key)
        chunk_ptr = source_ptr + start_pos
        @b3_update.call(buffers.hasher_buf, chunk_ptr, length)
        @b3_finalize.call(buffers.hasher_buf, buffers.out_buf, self.class::OUT_LEN)
        buffers.out_buf.to_str(self.class::OUT_LEN).b.freeze
      end
    end

    # Initializes native BLAKE3 function bindings from the shared library.
    #
    # @return [void]
    def init_blake3_lib
      so_path = self.class.find_blake3_so
      lib = Fiddle.dlopen(so_path)
      @b3_init_keyed = Fiddle::Function.new(lib["blake3_hasher_init_keyed"],
                                            [Fiddle::TYPE_VOIDP, Fiddle::TYPE_VOIDP], Fiddle::TYPE_VOID)
      @b3_update = Fiddle::Function.new(lib["blake3_hasher_update"],
                                        [Fiddle::TYPE_VOIDP, Fiddle::TYPE_VOIDP, Fiddle::TYPE_SIZE_T], Fiddle::TYPE_VOID)
      @b3_finalize = Fiddle::Function.new(lib["blake3_hasher_finalize"],
                                          [Fiddle::TYPE_VOIDP, Fiddle::TYPE_VOIDP, Fiddle::TYPE_SIZE_T], Fiddle::TYPE_VOID)
    end

    private

    # Returns thread-local BLAKE3 buffers, creating them if needed.
    #
    # @return [Blake3Buffers] the thread-local buffers
    def thread_local_buffers
      Thread.current[self.class::THREAD_STORAGE_KEY] ||= Blake3Buffers.new
    end
  end
end
