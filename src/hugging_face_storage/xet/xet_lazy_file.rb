# frozen_string_literal: true

module HuggingFaceStorage
  # Lazily-loaded remote file backed by Xet (content-addressable storage).
  # Defers metadata and content fetching until first access, with thread-safe
  # caching and streaming support.
  # @api private
  # :nodoc:
  class XetLazyFile
    # @return [String] the remote path of the file
    attr_reader :path

    # @param bucket_id [String] the bucket identifier
    # @param remote_path [String] path to the file in the bucket
    # @param api_client [ApiClient] API client for metadata requests
    # @param xet_downloader [XetDownloader] downloader for Xet content
    def initialize(bucket_id:, remote_path:, api_client:, xet_downloader:)
      @bucket_id = bucket_id
      @remote_path = remote_path
      @path = remote_path
      @api = api_client
      @xet_downloader = xet_downloader
      @metadata = nil
      @content = nil
      @metadata_mutex = Mutex.new
      @content_mutex = Mutex.new
    end

    # Fetches and caches file metadata (size, xet_hash, mtime).
    # @return [Hash{Symbol => String, Integer}] metadata hash with keys
    #   :path, :size, :xet_hash, :mtime
    # @raise [NotFoundError] if the file does not exist
    def metadata
      @metadata_mutex.synchronize do
        @metadata ||= begin
          results = @api.post(
            ApiPaths.paths_info_path(@bucket_id),
            body: { paths: [@remote_path] }
          )
          raise NotFoundError, "File not found: #{@remote_path}" if results.nil? || results.empty?

          info = results.first
          {
            path: info[ResponseFields::PATH],
            size: info[ResponseFields::SIZE],
            xet_hash: info[ResponseFields::XET_HASH],
            mtime: info[ResponseFields::MTIME],
          }
        end
      end
    end

    # Downloads and caches the file content via Xet.
    # @return [String] raw binary content
    def content
      @content_mutex.synchronize do
        @content ||= @xet_downloader.download_data(@bucket_id, @remote_path)
      end
    end

    # Reads the file content. With a block, yields the content chunk and
    # returns the byte size; without a block, returns the full content.
    # @yield [String] yields the content once if a block is given
    # @return [String, Integer] content string or bytesize when a block is given
    def read(&block)
      if block_given?
        chunk = content
        yield(chunk)
        chunk.bytesize
      else
        content
      end
    end

    # Writes the file content to a local path, creating directories as needed.
    # @param local_path [String] the destination filesystem path
    # @return [String] the local_path
    def save_to(local_path)
      FileUtils.mkdir_p(File.dirname(local_path))
      File.binwrite(local_path, content)
      local_path
    end

    # @return [Integer] file size in bytes
    def size
      metadata[:size]
    end

    # @return [String] the Xet content hash
    def xet_hash
      metadata[:xet_hash]
    end

    # @return [String, Integer] last modification time
    def mtime
      metadata[:mtime]
    end

    # @return [Boolean] whether content has been fetched and cached
    def loaded?
      !@content.nil?
    end

    # Streams file content in chunks without caching the full payload.
    # @param chunk_size [Integer] size of each chunk in bytes (default 64KB)
    # @yield [String] yields successive content chunks
    # @return [Enumerator, nil] an Enumerator when called without a block
    def content_streaming(chunk_size: 65_536, &block)
      return enum_for(:content_streaming, chunk_size: chunk_size) unless block

      @xet_downloader.download_data_streaming(@bucket_id, @remote_path, &block)
    end

    # Clears cached content and metadata to free memory.
    # @return [self]
    def release!
      @content_mutex.synchronize { @content = nil }
      @metadata_mutex.synchronize { @metadata = nil }
      self
    end

    # @return [String] a human-readable string representation of the lazy file
    def to_s
      "#<HuggingFaceStorage::XetLazyFile path=#{@remote_path.inspect} loaded=#{@content ? 'yes' : 'no'}>"
    end
    alias inspect to_s
  end
end
