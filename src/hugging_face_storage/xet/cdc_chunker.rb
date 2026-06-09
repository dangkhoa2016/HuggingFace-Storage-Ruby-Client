# frozen_string_literal: true

require_relative "gearhash_table"

module HuggingFaceStorage
  # Content-defined chunking using a gearhash-based algorithm for CDC.
  # @api private
  # :nodoc:
  class CdcChunker
    # Target chunk size in bytes.
    TARGET_CHUNK = 65_536
    # Minimum chunk size in bytes (1/8 of target).
    MIN_CHUNK = TARGET_CHUNK / 8
    # Maximum chunk size in bytes (2x target).
    MAX_CHUNK = TARGET_CHUNK * 2
    # Gear-hash mask for chunk boundary detection.
    MASK = 0xFFFF_0000_0000_0000
    # Size of the gear-hash sliding window in bytes.
    HASH_WINDOW = 64

    # Initializes a new CdcChunker.
    #
    # @param gearhash_table [Array<Integer>] pre-computed gear-hash table
    def initialize(gearhash_table:)
      @gearhash_table = gearhash_table
      @pending = "".b
      @gear_h = 0
      @cdc_state = nil
      init_cdc_state if defined?(HuggingFaceStorage::Gearhash::CdcState)
    end

    def self.gearhash_step(state, byte)
      ((state << 1) + GEARHASH_TABLE[byte]) & 0xFFFF_FFFF_FFFF_FFFF
    end

    def feed(data, &block)
      data = data.b
      if @cdc_state
        @cdc_state.feed(data).each(&block)
      else
        feed_ruby(data, &block)
      end
    end

    def finalize(&block)
      if @cdc_state
        @cdc_state.finalize.each(&block)
        @cdc_state = nil
        init_cdc_state
      else
        yield @pending unless @pending.empty?
        @pending = "".b
        @gear_h = 0
      end
    end

    private

    def init_cdc_state
      @cdc_state = HuggingFaceStorage::Gearhash::CdcState.new(@gearhash_table, MASK, MIN_CHUNK, MAX_CHUNK)
    end

    def feed_ruby(data)
      i = 0
      start = 0

      data.each_byte do |b|
        @gear_h = self.class.gearhash_step(@gear_h, b)
        size = @pending.bytesize + (i - start + 1)

        if chunk_boundary?(size)
          segment = data.byteslice(start, i - start + 1)
          chunk = @pending + segment
          @pending = "".b
          @gear_h = 0
          start = i + 1
          yield chunk
        end
        i += 1
      end

      @pending << data.byteslice(start, data.bytesize - start) if start < data.bytesize
    end

    def chunk_boundary?(size)
      size >= MIN_CHUNK && (size >= MAX_CHUNK || @gear_h.nobits?(MASK))
    end

    public

    # Chunks data using CDC with the optimized two-pass C implementation.
    # Pass 1: boundary scan (zero Ruby allocations).
    # Pass 2: batch output array construction.
    #
    # @param data [String] input binary data
    # @return [Array<Array(Integer, Integer)>] array of [start, end) ranges
    def cdc_chunk(data)
      if defined?(HuggingFaceStorage::Gearhash) && HuggingFaceStorage::Gearhash.respond_to?(:cdc_chunk)
        HuggingFaceStorage::Gearhash.cdc_chunk(data, MASK, MIN_CHUNK, MAX_CHUNK, @gearhash_table)
      else
        cdc_chunk_ruby(data)
      end
    end

    # Pure-Ruby implementation of CDC chunking.
    #
    # @param data [String] input binary data
    # @return [Array<Array(Integer, Integer)>] array of [start, end) ranges
    def cdc_chunk_ruby(data)
      len = data.bytesize
      return [[0, len]] if len <= MIN_CHUNK

      chunks = [] # : Array[[Integer, Integer]]
      h = 0
      start = 0
      i = 0

      data.each_byte do |b|
        h = self.class.gearhash_step(h, b)
        size = i - start + 1

        if size >= MIN_CHUNK && (size >= MAX_CHUNK || h.nobits?(MASK))
          chunks << [start, i + 1]
          start = i + 1
          h = 0
        end
        i += 1
      end

      chunks << [start, len] if start < len
      chunks
    end
  end
end
