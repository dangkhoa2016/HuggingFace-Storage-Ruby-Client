# frozen_string_literal: true

module HuggingFaceStorage
  # Incrementally builds file representation entries during streaming upload.
  # @api private
  # :nodoc:
  class XetStreamRepresentationBuilder
    def initialize(hasher)
      @hasher = hasher
      @ranges = []
      @xorb_hashes = []
      @xorb_length = 0
    end

    # Resets internal state to begin tracking a new xorb's chunks.
    #
    # @return [void]
    def start_xorb
      @xorb_hashes = []
      @xorb_length = 0
    end

    # Records a chunk hash and length for the current xorb.
    #
    # @param chunk_hash [String] 32-byte chunk hash
    # @param chunk_length [Integer] chunk length in bytes
    # @return [void]
    def add_chunk(chunk_hash, chunk_length)
      @xorb_hashes << chunk_hash
      @xorb_length += chunk_length
    end

    # Finalizes the current xorb, computing its range hash and appending to the range list.
    #
    # @param xorb_hash [String] 32-byte xorb hash
    # @return [void]
    def finalize_xorb(xorb_hash)
      return if @xorb_hashes.empty?

      idx_end = @xorb_hashes.length
      @ranges << {
        xorb_hash: xorb_hash,
        index_start: 0,
        index_end: idx_end,
        length: @xorb_length,
        range_hash: @hasher.compute_verification_hash(@xorb_hashes),
      }
      @xorb_hashes = []
      @xorb_length = 0
    end

    # Finalizes any remaining xorb and returns all accumulated ranges.
    #
    # @return [Array<Hash>] array of representation range entries
    def finalize
      finalize_xorb(nil) unless @xorb_hashes.empty?
      @ranges
    end
  end
end
