# frozen_string_literal: true

module HuggingFaceStorage
  class FileManager
    # Fetches file metadata and existence checks from the API.
    class Metadata
      def initialize(api_client:, bucket_id:, logger:)
        @api = api_client
        @bucket_id = bucket_id
        @logger = logger
      end

      # Fetches metadata for a single file.
      #
      # @param path [String] file path
      # @return [FileInfo] file metadata
      # @raise [NotFoundError] if the file is not found
      def metadata(path)
        @logger.debug { "Fetching metadata: #{path}" }
        results = @api.post(ApiPaths.paths_info_path(@bucket_id), body: { paths: [path] })
        raise NotFoundError, "File not found: #{path}" if results.nil? || results.empty?

        info = results.first
        FileInfo.new(
          path: info[ResponseFields::PATH], size: info[ResponseFields::SIZE],
          xet_hash: info[ResponseFields::XET_HASH], mtime: info[ResponseFields::MTIME]
        )
      end

      # Checks whether a file exists in the bucket.
      #
      # @param path [String] file path
      # @return [Boolean] true if the file exists
      def exists?(path)
        @logger.debug { "Checking existence: #{path}" }
        @api.file_exists?(@bucket_id, path)
      end
    end
  end
end
