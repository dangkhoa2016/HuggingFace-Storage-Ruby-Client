# frozen_string_literal: true

module HuggingFaceStorage
  # Mixin for loading and normalizing tree entry data.
  # @api private
  # :nodoc:
  module TreeLoader
    module_function

    # Loads tree entries from a file path or array.
    #
    # @param tree [String, Array<Hash, Symbol>] JSON file path or array of entries
    # @return [Array<Hash>] normalized tree entries
    # @raise [Error] if the tree path is invalid or file not found
    # @raise [ArgumentError] if tree is not a String or Array
    def load(tree)
      entries = if tree.is_a?(String)
                  raise Error, "Invalid tree path: #{tree}" if tree.match?(%r{(^|/)\.\.(/|$)})

                  raise Error, "Tree file not found: #{tree}" unless File.file?(tree)

                  JSON.parse(File.read(tree))
                elsif tree.is_a?(Array)
                  tree.map { |e| normalize_entry(e) }
                else
                  raise ArgumentError, "tree must be a file path (String) or Array of entries"
                end
      raise Error, "Tree entries must be an array" unless entries.is_a?(Array)

      entries
    end

    # Normalizes a single entry to Hash format with string keys.
    #
    # @param entry [Hash, Symbol] raw entry data
    # @return [Hash] normalized entry
    def normalize_entry(entry)
      if entry.is_a?(Hash)
        if entry.key?("path")
          entry
        else
          { "path" => entry[:path], "xetHash" => entry[:xet_hash], "size" => entry[:size],
            "type" => "file" }
        end
      else
        { "path" => entry.to_s, "xetHash" => nil, "size" => nil, "type" => "file" }
      end
    end
  end
end
