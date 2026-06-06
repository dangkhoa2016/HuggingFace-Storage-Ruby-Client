# frozen_string_literal: true

module HuggingFaceStorage
  class CrossRepoCopyService
    # Handles tree-based copy operations by filtering entries and mapping destinations.
    class TreeCopyStrategy
      # @param api_client [ApiClient] the API client
      # @param file_manager [FileManager] the file manager
      # @param bucket_id [String] the destination bucket ID
      # @param logger [Logger] logger instance
      def initialize(api_client:, file_manager:, bucket_id:, logger:)
        @api = api_client
        @files = file_manager
        @bucket_id = bucket_id
        @logger = logger
      end

      # Copies files from a tree listing into the destination bucket.
      #
      # @param tree [Array<Hash>, String] tree data or JSON string
      # @param source_type [String] source type
      # @param source_repo [String] source repository name
      # @param source_prefix [String, nil] optional source path prefix filter
      # @param destination_prefix [String, nil] optional destination prefix
      # @param exclude [Array<String>, nil] glob patterns to exclude
      # @param overwrite [Boolean] overwrite existing files
      # @param cancel_token [CancelToken, nil] optional cancellation token
      # @return [Hash] result with :files_copied, :skipped, :total_size, :source
      def call(tree:, source_type:, source_repo:, source_prefix: nil, destination_prefix: nil,
               exclude: nil, overwrite: false, cancel_token: nil)
        entries = TreeLoader.load(tree)
        entries = filter_tree_entries(entries, source_prefix, exclude)
        raise Error, "No matching files found in tree" if entries.empty?

        files = build_destination_map(entries, source_prefix, destination_prefix)

        unless overwrite
          before = files.size
          skipped = skip_existing_files(files)
          if files.empty?
            @logger.info("  Nothing to copy - all #{before} source file(s) already exist")
            return { files_copied: 0, skipped: skipped, total_size: 0, source: "#{source_type}:#{source_repo}" }
          end
        end

        total_size = files.sum { |f| f[:size] }
        @logger.info(
          "Copy from tree: #{files.size} file(s), " \
          "#{Utils.human_size(total_size)} from #{source_type}:#{source_repo}"
        )
        cancel_token&.raise_if_cancelled!
        @files.copy_from(source_type: source_type, source_repo: source_repo, files: files, cancel_token: cancel_token)
        @logger.info("Copy from tree complete: #{files.size} file(s)")
        { files_copied: files.size, total_size: total_size, source: "#{source_type}:#{source_repo}" }
      end

      private

      # Filters tree entries to file types, applies source prefix filter and exclusion patterns.
      #
      # @param entries [Array<Hash>] raw tree entries
      # @param source_prefix [String, nil] source path prefix filter
      # @param exclude [Array<String>, nil] glob patterns to exclude
      # @return [Array<Hash>] filtered entries
      def filter_tree_entries(entries, source_prefix, exclude)
        entries = entries.select { |e| e[ResponseFields::TYPE] == ResponseFields::FILE_TYPE && e[ResponseFields::XET_HASH] }
        if source_prefix
          prefix = "#{source_prefix.sub(%r{/+\z}, '')}/"
          entries = entries.select { |e| e[ResponseFields::PATH].start_with?(prefix) || e[ResponseFields::PATH] == source_prefix }
        end
        entries.reject! { |e| ExcludeMatcher.match?(e[ResponseFields::PATH], exclude) } if exclude
        entries
      end

      # Maps tree entries to destination paths, applying prefix transformations.
      #
      # @param entries [Array<Hash>] filtered tree entries
      # @param source_prefix [String, nil] source prefix to strip
      # @param destination_prefix [String, nil] destination prefix to prepend
      # @return [Array<Hash>] mapped entries with :xet_hash, :destination, :source_path, :size
      def build_destination_map(entries, source_prefix, destination_prefix)
        dest = destination_prefix ? Paths.normalize(destination_prefix) : nil
        entries.map do |e|
          src_path = e[ResponseFields::PATH]
          if dest && source_prefix
            relative = src_path.sub(%r{^#{Regexp.escape(source_prefix.sub(%r{/+\z}, ''))}/?}, "")
            dst = "#{dest}/#{relative}"
          elsif dest
            dst = "#{dest}/#{src_path}"
          else
            dst = src_path
          end
          { xet_hash: e[ResponseFields::XET_HASH], destination: dst, source_path: src_path, size: e[ResponseFields::SIZE] }
        end
      end

      # Removes files that already exist in the destination bucket.
      #
      # @param files [Array<Hash>] file entries with :destination
      # @return [Integer] number of files skipped
      def skip_existing_files(files)
        before = files.size
        skipped = BucketQuery.reject_existing!(@api, @bucket_id, files, path_key: :destination)
        @logger.info("  Skipped #{skipped}/#{before} file(s) already exist at destination") if skipped.positive?
        skipped
      end
    end
  end
end
