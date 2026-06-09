# frozen_string_literal: true

module HuggingFaceStorage
  # Builds a Merkle-tree-style XOR hash from a list of chunk hashes.
  class XorbHashTree
    # The hash returned for an empty list of chunk hashes (32 zero bytes).
    EMPTY_XORB_HASH = ([0] * 32).pack("C*").freeze

    # Builds a xorb hash from chunk hashes using pairwise XOR reduction.
    #
    # @param chunk_hashes [Array<String>] array of 32-byte chunk hashes
    # @param validate [Boolean] whether to validate hash sizes (default: true)
    #   Set to false for trusted internal input to skip O(n) validation scan
    # @return [String] 32-byte xorb hash (or EMPTY_XORB_HASH for empty input)
    def build(chunk_hashes, validate: true)
      return EMPTY_XORB_HASH if chunk_hashes.empty?

      raise ArgumentError, "all chunk hashes must be 32 bytes" if validate && chunk_hashes.any? { |h| h.bytesize != 32 }

      return chunk_hashes.first if chunk_hashes.one?

      # Work on a copy to avoid mutating the caller's array
      hashes = chunk_hashes.dup

      while hashes.length > 1
        write_idx = 0
        read_idx = 0
        while read_idx < hashes.length
          left = hashes[read_idx]
          right = read_idx + 1 < hashes.length ? hashes[read_idx + 1] : nil
          hashes[write_idx] = right ? xorb_xor(left, right) : left # steep:ignore
          write_idx += 1
          read_idx += 2
        end
        hashes.pop(hashes.length - write_idx) if write_idx < hashes.length
      end

      hashes.first
    end

    private

    def xorb_xor(lhs, rhs)
      if defined?(HuggingFaceStorage::Gearhash) && HuggingFaceStorage::Gearhash.respond_to?(:xorb_xor)
        HuggingFaceStorage::Gearhash.xorb_xor(lhs, rhs) # steep:ignore
      else
        lhs.bytes.zip(rhs.bytes).map { |x, y| x ^ y }.pack("C*")
      end
    end
  end
end
