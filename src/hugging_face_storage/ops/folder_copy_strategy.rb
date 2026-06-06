# frozen_string_literal: true

module HuggingFaceStorage
  class CrossRepoCopyService
    # Handles folder-level copy operations by normalizing paths and classifying entries.
    class FolderCopyStrategy
      # @param api_client [ApiClient] the API client
      # @param source_iterator [SourceIterator] the source iterator
      # @param logger [Logger] logger instance
      def initialize(api_client:, source_iterator:, logger:)
        @api = api_client
        @source_iterator = source_iterator
        @logger = logger
      end

      # Processes folder copy specifications by normalizing destinations and classifying entries.
      #
      # @param folders [Array<Hash>] folder copy specifications with :source_type, :source_repo, etc.
      # @param cancel_token [CancelToken, nil] optional cancellation token
      # @return [Hash] result with :copy_ops, :pending_downloads, :results
      def call(folders:, cancel_token:)
        folders = folders.map do |f|
          dest = if f[:destination].end_with?("/")
                   "#{f[:destination]}#{File.basename(f[:source_path].sub(%r{/+\z}, ''))}"
                 else
                   f[:destination]
                 end
          dest = dest.gsub(%r{/{2,}}, "/")
          f.merge(destination: dest)
        end

        all_copy_ops, all_pending_downloads, folder_results = process_folder_sources(folders, cancel_token)
        { copy_ops: all_copy_ops, pending_downloads: all_pending_downloads, results: folder_results }
      end

      private

      # Iterates over folders and classifies entries via SourceIterator.
      #
      # @param folders [Array<Hash>] folder copy specifications
      # @param cancel_token [CancelToken, nil] optional cancellation token
      # @return [Array] tuple of [all_copy_ops, all_pending_downloads, folder_results]
      def process_folder_sources(folders, cancel_token)
        @source_iterator.iterate_and_classify(folders) do |builder, folder|
          source_type = folder[:source_type]
          source_repo = folder[:source_repo]
          source_path = folder[:source_path].sub(%r{/+\z}, "")
          destination = folder[:destination]
          revision = folder[:revision] || "main"
          exclude = folder[:exclude]
          source_base = source_path.empty? ? "" : source_path

          @logger.info("Copy folder: #{source_type}:#{source_repo}/#{source_path} -> #{destination}")

          result = builder.process_source(
            source_type: source_type, source_repo: source_repo,
            source_path: source_path.empty? ? nil : source_path,
            revision: revision, destination: destination, exclude: exclude,
            destination_mapper: lambda { |entry|
              src_path = entry[ResponseFields::PATH]
              rel_path = source_base.empty? ? src_path : src_path.sub(%r{^#{Regexp.escape(source_base)}/?}, "")
              rel_path.empty? ? destination : "#{destination}/#{rel_path}"
            },
            cancel_token: cancel_token
          )

          @source_iterator.wrap_source_result(result,
                                              from: "#{source_type}:#{source_repo}/#{source_path}",
                                              to: destination, source_base: source_base)
        end
      end
    end
  end
end
