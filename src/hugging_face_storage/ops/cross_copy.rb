# frozen_string_literal: true

module HuggingFaceStorage
  class FileManager
    # Handles cross-repository file copy operations (bucket to bucket).
    class CrossCopy
      def initialize(api_client:, bucket_id:, logger:)
        @api = api_client
        @bucket_id = bucket_id
        @logger = logger
      end

      # Copies files from an external repository into this bucket via batch API.
      #
      # @param source_type [String] source repository type
      # @param source_repo [String] source repository identifier
      # @param files [Array<Hash>] file entries with :destination and :xet_hash
      # @param cancel_token [CancelToken, nil] cooperative cancellation token
      # @return [Object] batch API result
      def copy_from(source_type:, source_repo:, files:, cancel_token: nil)
        @logger.info("Cross-copy: #{source_type}:#{source_repo} -> #{@bucket_id} (#{files.size} file(s))")
        operations = files.map do |f|
          {
            type: ApiOperations::COPY_FILE,
            path: f[:destination],
            xetHash: f[:xet_hash],
            sourceRepoType: source_type,
            sourceRepoId: source_repo,
          }
        end
        @api.batch(@bucket_id, operations, cancel_token: cancel_token)
      end
    end
  end
end
