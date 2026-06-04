# frozen_string_literal: true

module HuggingFaceStorage
  # Utility functions for path normalization and encoding.
  # @api private
  # :nodoc:
  module Paths
    module_function

    # Removes leading and trailing slashes from +path+.
    #
    # @param path [String] the path to normalize
    # @return [String] the normalized path
    def normalize(path)
      path.to_s.sub(%r{\A/+}, "").sub(%r{/+\z}, "")
    end

    # Removes leading slashes from +path+.
    #
    # @param path [String] the path to strip
    # @return [String] the path without a leading slash
    def strip_leading_slash(path)
      path.to_s.sub(%r{\A/+}, "")
    end

    # URL-encodes each path segment individually.
    #
    # @param path [String] the path to encode
    # @return [String] the encoded path
    def encode_segments(path)
      path.split("/").map { |s| URI.encode_www_form_component(s).gsub("+", "%20") }.join("/")
    end

    # Returns the parent directory of the given path.
    #
    # @param path [String] the file path
    # @return [String] parent directory
    def parent(path)
      File.dirname(path)
    end
  end
end
