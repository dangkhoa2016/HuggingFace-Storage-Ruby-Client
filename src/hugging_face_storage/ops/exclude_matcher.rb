# frozen_string_literal: true

module HuggingFaceStorage
  # Checks file paths against exclude patterns.
  module ExcludeMatcher
    module_function

    # Returns true if +path+ matches any of the +patterns+.
    #
    # @param path [String] file path to check
    # @param patterns [String, Array<String>] glob pattern(s) to match against
    # @return [Boolean] whether the path matches any pattern
    def match?(path, patterns)
      patterns = Array(patterns)
      basename = File.basename(path)
      patterns.any? do |pattern|
        File.fnmatch?(pattern, path, File::FNM_PATHNAME | File::FNM_DOTMATCH) ||
          File.fnmatch?(pattern, basename, File::FNM_DOTMATCH)
      end
    end
  end
end
