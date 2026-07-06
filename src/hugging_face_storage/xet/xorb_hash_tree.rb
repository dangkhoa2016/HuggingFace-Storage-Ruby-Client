# frozen_string_literal: true

module HuggingFaceStorage
  # Builds a Merkle-tree-style XOR hash from a list of chunk hashes.
  class XorbHashTree
    # The hash returned for an empty list of chunk hashes (32 zero bytes).
    EMPTY_XORB_HASH = ([0] * 32).pack("C*").freeze

    # Builds a xorb hash from chunk hashes using pairwise XOR reduction.
    #
    # @param chunk_hashes [Array<String>] array of 32-byte chunk hashes
    # @return [String] 32-byte xorb hash (or EMPTY_XORB_HASH for empty input)
    def build(chunk_hashes)
      return EMPTY_XORB_HASH if chunk_hashes.empty?

      raise ArgumentError, "all chunk hashes must be 32 bytes" if chunk_hashes.any? { |h| h.bytesize != 32 }

      return chunk_hashes.first if chunk_hashes.one?

      while chunk_hashes.length > 1
        chunk_hashes = chunk_hashes.each_slice(2).map do |left, right|
          next left unless right

          left.bytes.zip(right.bytes).map { |a, b| a ^ b }.pack("C*")
        end
      end

      chunk_hashes.first
    end
  end
end
