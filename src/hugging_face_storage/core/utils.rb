# frozen_string_literal: true

module HuggingFaceStorage
  # Mixin with general-purpose utility methods.
  module Utils
    module_function

    # Converts a 32-byte hash digest to a hex string.
    #
    # @param hash_bytes [String] 32-byte binary hash
    # @return [String] hex-encoded hash string
    # @raise [ArgumentError] if hash_bytes is not 32 bytes
    def hash_to_hex(hash_bytes)
      raise ArgumentError, "hash_to_hex requires 32 bytes, got #{hash_bytes.bytesize}" unless hash_bytes.bytesize == 32

      hash_bytes.unpack1("H*")
    end

    # Returns a human-readable size string for byte counts.
    #
    # @param bytes [Integer] size in bytes
    # @return [String] human-readable size (e.g. "1.5 MB")
    def human_size(bytes)
      case bytes
      when 0 then "0 B"
      when 1...1024 then "#{bytes} B"
      when 1024...1_048_576 then format("%.1f KB", bytes / 1024.0)
      when 1_048_576...1_073_741_824 then format("%.1f MB", bytes / 1_048_576.0)
      when 1_073_741_824...1_099_511_627_776 then format("%.1f GB", bytes / 1_073_741_824.0)
      else format("%.1f TB", bytes / 1_099_511_627_776.0)
      end
    end

    # Extracts the "next" link from an HTTP Link header.
    #
    # @param response [Net::HTTPResponse] the HTTP response
    # @return [String, nil] the next page URL, or nil if absent
    def extract_next_link(response)
      link_header = response["link"] || response["Link"]
      return nil unless link_header

      link_header.split(",").each do |part|
        return Regexp.last_match(1) if part =~ /<([^>]+)>;\s*rel="next"/
      end
      nil
    end
  end
end
