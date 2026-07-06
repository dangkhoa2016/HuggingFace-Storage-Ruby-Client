# frozen_string_literal: true

module HuggingFaceStorage
  # Serializes xorb chunk data into binary format for Xet storage.
  # @api private
  # :nodoc:
  module XetXorbBuilder
    SERIALIZE_HEADER_FMT = "CCxCCx"
    MAX_24BIT = 0xFF_FFFF

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
  end
end
