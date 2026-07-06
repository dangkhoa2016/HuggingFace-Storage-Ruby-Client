# frozen_string_literal: true

module HuggingFaceStorage
  # Collects local files from a directory tree with exclusion support.
  # @api private
  # :nodoc:
  module LocalFileCollector
    module_function

    # Returns a sorted list of file paths under +local_dir+ matching the exclude rules.
    #
    # @param local_dir [String] root directory to scan
    # @param exclude [Array<String>, nil] glob patterns to exclude
    # @return [Array<String>] matching file paths
    def collect(local_dir, exclude)
      pattern = File.join(local_dir, "**", "*")
      files = Dir.glob(pattern, File::FNM_DOTMATCH).select { |f| File.file?(f) }.sort

      if exclude
        files.reject! do |f|
          relative = f.sub("#{local_dir}/", "")
          ExcludeMatcher.match?(relative, exclude)
        end
      end

      files
    end
  end
end
