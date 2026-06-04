# frozen_string_literal: true

module HuggingFaceStorage
  # Applies in-place edits to remote files via download-patch-upload.
  # @api private
  # :nodoc:
  class FileEditor
    # @param api_client [ApiClient] the API client
    # @param xet_uploader [XetUploader] uploader for patched data
    # @param xet_downloader [XetDownloader] downloader for original data
    # @param bucket_id [String] bucket identifier
    # @param config [Configuration] configuration
    # @param logger [Logger] logger instance
    def initialize(api_client:, xet_uploader:, xet_downloader:, bucket_id:, config:, logger:)
      @api = api_client
      @xet_uploader = xet_uploader
      @xet_downloader = xet_downloader
      @bucket_id = bucket_id
      @config = config
      @logger = logger
    end

    # Downloads, patches, and re-uploads a remote file.
    #
    # @param remote_path [String] path of the remote file
    # @param edits [Array<Hash>] edit operations
    # @param cancel_token [CancelToken, nil] optional cancellation token
    # @return [Hash] upload result
    def edit(remote_path, edits:, cancel_token: nil)
      parse_and_validate_edits(edits)
      @logger.info("Editing file: #{remote_path} (#{edits.size} edit(s))")
      cancel_token&.raise_if_cancelled!

      guard_edit_size!(remote_path)
      @logger.debug { "Edit file: #{remote_path} (#{edits.size} edit(s))" }

      fetch_backup_and_apply(remote_path, edits, cancel_token)
    end

    private

    def guard_edit_size!(remote_path)
      limit = @config.max_edit_file_size
      return unless limit

      info = begin
        fetch_info(remote_path)
      rescue StandardError => e
        @logger.warn("Could not determine size of #{remote_path} (#{e.class}); skipping size guard")
        nil
      end
      return unless info && info[:size]

      return if info[:size] <= limit

      raise Error,
            "Refusing to edit #{remote_path}: file size (#{Utils.human_size(info[:size])}) exceeds " \
            "max_edit_file_size (#{Utils.human_size(limit)}). Raise the limit via Configuration if needed."
    end

    # Expands "replace" type edits into positional edits by locating patterns in the original content.
    #
    # @param edits [Array<Hash>] edit operations
    # @param original [String] original file content
    # @return [Array<Hash>] expanded positional edits
    def expand_replace_edits(edits, original)
      edits.flat_map do |edit|
        next [edit] unless edit[:type] == "replace"

        old_str = edit[:old]
        unless old_str.is_a?(String) && !old_str.empty?
          raise ArgumentError,
                "edit[replace]: :old must be a non-empty String"
        end

        new_str = (edit[:new] || "").b
        max = edit[:max_replacements]
        # @type var expanded: Array[Hash[Symbol, (Integer | String)]]
        expanded = []
        offset = 0
        while (idx = original.index(old_str, offset))
          expanded << { start: idx, end: idx + old_str.bytesize, content: new_str }
          offset = idx + 1
          break if max && expanded.size >= max
        end
        raise ArgumentError, "edit[replace]: pattern not found: #{old_str[0..80].inspect}" if expanded.empty?

        expanded
      end
    end

    def parse_and_validate_edits(edits)
      raise ArgumentError, "edits must be a non-empty Array" unless edits.is_a?(Array) && !edits.empty?

      edits.each_with_index do |edit, i|
        raise ArgumentError, "edit[#{i}] must be a Hash" unless edit.is_a?(Hash)

        next if edit[:type] == "replace"

        start = edit[:start] || edit[:offset]
        raise ArgumentError, "edit[#{i}] requires :start or :offset (Integer)" unless start
        unless start.is_a?(Integer) && start >= 0
          raise ArgumentError,
                "edit[#{i}]: :start must be a non-negative Integer"
        end
      end
    end

    # Downloads, patches, and re-uploads a remote file.
    #
    # @param remote_path [String] remote file path
    # @param edits [Array<Hash>] edit operations
    # @param cancel_token [CancelToken, nil] cooperative cancellation token
    # @return [Hash] upload result
    def fetch_backup_and_apply(remote_path, edits, cancel_token)
      original = @xet_downloader.download_data(@bucket_id, remote_path, cancel_token: cancel_token)
      expanded = expand_replace_edits(edits, original)
      patched = apply_edits_to_content(original, expanded)
      cancel_token&.raise_if_cancelled!
      result = @xet_uploader.upload_data(@bucket_id, patched, remote_path, cancel_token: cancel_token)
      @logger.info("Edit complete: #{remote_path}")
      result
    end

    def apply_edits_to_content(original, expanded)
      sorted = expanded.sort_by { |e| -(e[:start] || e[:offset] || 0) }
      patched = original.dup
      sorted.each do |edit|
        start = edit[:start] || edit[:offset] || 0
        len = edit[:end] ? (edit[:end] - start) : (edit[:length] || 0)
        content = (edit[:content] || "").b
        suffix = patched.byteslice(start + len, patched.bytesize) || "".b
        patched = patched.byteslice(0, start) + content + suffix
      end
      patched
    end

    # Fetches file info (xet_hash, size) from the API.
    #
    # @param path [String] remote file path
    # @return [Hash] file info hash
    def fetch_info(path)
      BucketQuery.fetch_file_info(@api, @bucket_id, path)
    end
  end
end
