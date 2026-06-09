# frozen_string_literal: true

module HuggingFaceStorage
  # Serializes xorb chunk data into binary format for Xet storage.
  # @api private
  # :nodoc:
  module XetXorbBuilder
    SERIALIZE_HEADER_FMT = "CCxCCx"
    MAX_24BIT = 0xFF_FFFF

    HEADER_TABLE_SIZE = 256

    # Pre-computed header lookup table for chunk sizes 0-255.
    # Each entry is 8 bytes: \x00 + 3-byte LE size + \x00 + 3-byte LE size
    # Frozen to prevent accidental modification and enable memory sharing.
    HEADER_TABLE = Array.new(HEADER_TABLE_SIZE) do |i|
      size_bytes = [i].pack("V")[0, 3]
      "\x00#{size_bytes}\x00#{size_bytes}".b.freeze
    end.freeze

    def serialize_xorb(chunks_data)
      total_size = chunks_data.sum { |c| XetHasher::CHUNK_HEADER_SIZE + c.bytesize }
      buf = String.new(capacity: total_size, encoding: Encoding::BINARY)
      chunks_data.each do |chunk|
        size = chunk.bytesize
        raise ArgumentError, "chunk size #{size} exceeds 24-bit limit (#{MAX_24BIT})" if size > MAX_24BIT

        sb = [size].pack("V")[0, 3]
        buf << "\x00".b << sb << "\x00".b << sb << chunk
      end
      buf
    end

    # Serializes xorb data directly from source buffer using pre-computed ranges.
    # Eliminates per-chunk String allocation by writing headers and chunk data
    # into a single pre-allocated output buffer via memcpy.
    #
    # @param data [String] source binary data
    # @param ranges [Array<Array(Integer, Integer)>] array of [start, end) ranges
    # @return [String] serialized xorb binary data
    def serialize_xorb_from_ranges(data, ranges)
      if defined?(HuggingFaceStorage::Gearhash) && HuggingFaceStorage::Gearhash.respond_to?(:serialize_xorb_from_ranges)
        HuggingFaceStorage::Gearhash.serialize_xorb_from_ranges(data, ranges)
      else
        serialize_xorb_fallback(data, ranges)
      end
    end

    # Serializes multiple chunks from different source buffers into a single xorb.
    # Zero-copy: reads directly from source buffers without intermediate copies.
    #
    # Uses pre-computed header lookup table for small chunk sizes (0-255) to avoid
    # per-chunk String allocation from pack("V") and string literals.
    #
    # @param chunk_infos [Array<Array(String, Integer, Integer, String)>] array of
    #   [source, offset, length, hash] tuples (preferred format)
    # @param chunk_infos [Array<Hash>] array of {source: String, offset: Integer, length: Integer} (legacy format)
    # @return [String] serialized xorb binary data
    def serialize_xorb_from_ranges_concat(chunk_infos)
      total_size = chunk_infos.sum { |c| XetHasher::CHUNK_HEADER_SIZE + chunk_length(c) }
      buf = String.new(capacity: total_size, encoding: Encoding::BINARY)

      chunk_infos.each do |info|
        size = chunk_length(info)
        raise ArgumentError, "chunk size #{size} exceeds 24-bit limit (#{MAX_24BIT})" if size > MAX_24BIT

        # Use pre-computed header for small sizes, manual construction for large
        header = size < HEADER_TABLE_SIZE ? HEADER_TABLE[size] : build_chunk_header(size)
        buf << header

        buf << chunk_source(info).byteslice(chunk_offset(info), size)
      end
      buf
    end

    def pack_xorbs(all_chunks)
      xorbs = [] # : Array[Hash[Symbol, untyped]]
      current_chunks = [] # : Array[Hash[Symbol, untyped]]
      current_size = 0

      all_chunks.each do |chunk|
        chunk_total = XetHasher::CHUNK_HEADER_SIZE + chunk[:data].bytesize

        if current_size + chunk_total > XetHasher::XORB_MAX_SIZE || current_chunks.length >= XetHasher::XORB_MAX_CHUNKS
          xorbs << finalize_xorb(current_chunks) unless current_chunks.empty?
          current_chunks = []
          current_size = 0
        end

        current_chunks << chunk
        current_size += chunk_total
      end

      xorbs << finalize_xorb(current_chunks) unless current_chunks.empty?
      xorbs
    end

    def finalize_xorb(chunks)
      data = serialize_xorb(chunks.map { |c| c[:data] })
      chunks_info = chunks.map { |c| { hash: c[:hash], length: c[:length] } }
      hash = @hasher.compute_xorb_hash(chunks_info)
      { data: data, hash: hash, chunks: chunks }
    end

    # Extracts chunk length from either tuple or Hash format.
    def chunk_length(chunk)
      chunk.is_a?(Array) ? chunk[2] : chunk[:length]
    end

    # Extracts source buffer from either tuple or Hash format.
    def chunk_source(chunk)
      chunk.is_a?(Array) ? chunk[0] : chunk[:source]
    end

    # Extracts offset from either tuple or Hash format.
    def chunk_offset(chunk)
      chunk.is_a?(Array) ? chunk[1] : chunk[:offset]
    end

    # Builds 8-byte chunk header for sizes >= 256.
    def build_chunk_header(size)
      size_bytes = [size].pack("V")[0, 3]
      "\x00#{size_bytes}\x00#{size_bytes}".b
    end

    private

    # Pure-Ruby fallback for serialize_xorb_from_ranges.
    #
    # @param data [String] source binary data
    # @param ranges [Array<Array(Integer, Integer)>] array of [start, end) ranges
    # @return [String] serialized xorb binary data
    def serialize_xorb_fallback(data, ranges)
      total_size = ranges.sum { |s, e| XetHasher::CHUNK_HEADER_SIZE + (e - s) }
      buf = String.new(capacity: total_size, encoding: Encoding::BINARY)
      ranges.each do |start_pos, end_pos|
        size = end_pos - start_pos
        raise ArgumentError, "chunk size #{size} exceeds 24-bit limit (#{MAX_24BIT})" if size > MAX_24BIT

        sb = [size].pack("V")[0, 3]
        buf << "\x00".b << sb << "\x00".b << sb << data.byteslice(start_pos, size)
      end
      buf
    end
  end
end
