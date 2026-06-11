# frozen_string_literal: true

require "fileutils"
require "net/http"
require "uri"

module HuggingFaceStorage
  module CasDownloadHelpers
    private

    def stream_cas_data(bucket_id, metadata, cancel_token: nil, &block)
      cancel_token&.raise_if_cancelled!
      read_info = @token_manager.fetch_read_token(bucket_id)
      uri = URI.parse("#{read_info[:endpoint]}/v1/reconstructions/#{metadata[:xet_hash]}")
      cas_stream_to_file(uri, read_info[:token], cancel_token: cancel_token, &block)
    end

    def stream_download_via_cas(bucket_id, metadata, local_path, cancel_token: nil)
      cancel_token&.raise_if_cancelled!
      read_info = @token_manager.fetch_read_token(bucket_id)
      cas_url = read_info[:endpoint]
      token = read_info[:token]
      xet_hash = metadata[:xet_hash]
      raise Error, "No xetHash available" unless xet_hash

      uri = URI.parse("#{cas_url}/v1/reconstructions/#{xet_hash}")
      File.open(local_path, "wb") do |file|
        cas_stream_to_file(uri, token, cancel_token: cancel_token) do |chunk|
          file.write(chunk)
        end
      end
    end

    def cas_stream_to_file(uri, token, max_redirects: 5, cancel_token: nil, &block)
      pool = @transport&.http_pool || @http_pool
      rt = @transport&.retryable || @retryable
      rf = RedirectFollower.new(http_pool: pool)
      rt.retry_with_backoff(@config, cancel_token: cancel_token, logger: @logger) do |_retries|
        rf.follow_redirects(uri, max_redirects: max_redirects, cancel_token: cancel_token, streaming: true,
                                 failure_message: "Reconstruction fetch failed", cas_token: token, &block)
        return nil
      end
    end

    def download_via_cas(bucket_id, metadata, cancel_token: nil)
      cancel_token&.raise_if_cancelled!
      read_info = @token_manager.fetch_read_token(bucket_id)
      cas_url = read_info[:endpoint]
      xet_hash = metadata[:xet_hash]
      raise Error, "No xetHash available" unless xet_hash

      uri = URI.parse("#{cas_url}/v1/reconstructions/#{xet_hash}")
      cas_http_get(uri, bucket_id, cancel_token: cancel_token)
    end

    def cas_http_get(uri, bucket_id, cancel_token: nil)
      pool = @transport&.http_pool || @http_pool
      rt = @transport&.retryable || @retryable
      with_token_retry(bucket_id, label: "read") do |token|
        rt.retry_with_backoff(@config, cancel_token: cancel_token, logger: @logger) do |_retries|
          req = Net::HTTP::Get.new(uri.request_uri)
          req["Authorization"] = "Bearer #{token}"
          resp = pool.with_connection(uri) { |http| http.request(req) }
          code = resp.code.to_i
          unless ApiPaths::Status::OK.include?(code)
            raise ApiError.new(
              message: "Reconstruction fetch failed (HTTP #{code})",
              status: code
            )
          end

          resp.body.b
        end
      end.to_s
    end
  end

  # Downloads files and data from Xet storage via CAS or direct resolution.
  class XetDownloader
    include Instrumentation
    include TokenRetryable
    include TransportConfig
    include CasDownloadHelpers

    # Initializes a new XetDownloader.
    #
    # @param api_client [ApiClient] API client instance
    # @param token_manager [XetTokenManager] token manager instance
    # @param endpoint [String] API endpoint URL
    # @param logger [Logger, nil] logger instance
    # @param config [Configuration, nil] configuration object
    # @param metrics_registry [Object, nil] metrics registry
    # @param notifications [Module, nil] notifications module
    def initialize(api_client:, token_manager:, endpoint:, logger: nil, config: nil,
                   metrics_registry: nil, notifications: nil, transport: nil)
      @api = api_client
      @token_manager = token_manager
      @endpoint = endpoint
      @logger = logger || NullLogger.new
      @config = config || Configuration.default
      @metrics_registry = metrics_registry
      @notifications = notifications
      init_transport_config!(transport)
      @redirect_follower = RedirectFollower.new(http_pool: @http_pool) if @transport.nil?
    end

    # Downloads a file from Xet storage to a local path.
    #
    # @param bucket_id [String] the bucket ID
    # @param remote_path [String] remote file path
    # @param local_path [String] local destination path
    # @param cancel_token [CancelToken, nil] cooperative cancellation token
    # @return [void]
    def download_file(bucket_id, remote_path, local_path, cancel_token: nil)
      instrument("download_file", bucket_id: bucket_id, path: remote_path) do
        @logger.debug { "Xet download: #{remote_path} -> #{local_path}" }
        cancel_token&.raise_if_cancelled!
        FileUtils.mkdir_p(File.dirname(local_path))
        stream_download_to_file(bucket_id, remote_path, local_path, cancel_token: cancel_token)
        @logger.debug { "Xet download complete: #{local_path}" }
        @metrics_registry.increment(:bytes_downloaded, File.size(local_path)) if File.exist?(local_path)
      end
    end

    # Downloads file data as a binary string, falling back to CAS on server error.
    #
    # @param bucket_id [String] the bucket ID
    # @param remote_path [String] remote file path
    # @param cancel_token [CancelToken, nil] cooperative cancellation token
    # @return [String] binary file data
    def download_data(bucket_id, remote_path, cancel_token: nil)
      instrument("download_data", bucket_id: bucket_id, path: remote_path) do
        cancel_token&.raise_if_cancelled!
        uri = URI.parse("#{@endpoint}#{ApiPaths.resolve_path(bucket_id, remote_path)}")
        response = @api.request_with_redirect(uri, cancel_token: cancel_token)
        data = response.body.b
        @metrics_registry.increment(:bytes_downloaded, data.bytesize)
        data
      end
    rescue ApiError => e
      raise unless cas_eligible_error?(e)

      metadata = fetch_file_metadata(bucket_id, remote_path)
      download_via_cas(bucket_id, metadata, cancel_token: cancel_token)
    end

    # Downloads file data by streaming chunks, falling back to CAS on server error.
    #
    # @param bucket_id [String] the bucket ID
    # @param remote_path [String] remote file path
    # @param cancel_token [CancelToken, nil] cooperative cancellation token
    # @yield [String] yields binary chunks
    # @return [void]
    def download_data_streaming(bucket_id, remote_path, cancel_token: nil, &block)
      instrument("download_data_streaming", bucket_id: bucket_id, path: remote_path) do
        cancel_token&.raise_if_cancelled!
        uri = URI.parse("#{@endpoint}#{ApiPaths.resolve_path(bucket_id, remote_path)}")
        @api.stream_with_redirect(uri, cancel_token: cancel_token, &block)
      end
    rescue ApiError => e
      raise unless cas_eligible_error?(e)

      metadata = fetch_file_metadata(bucket_id, remote_path)
      stream_cas_data(bucket_id, metadata, cancel_token: cancel_token, &block)
    end

    # Fetches metadata for a remote file including size, hash, and mtime.
    #
    # @param bucket_id [String] the bucket ID
    # @param path [String] remote file path
    # @return [Hash{Symbol => String, Integer}] file metadata with :path, :size, :xet_hash, :mtime
    # @raise [NotFoundError] if the file is not found
    def fetch_file_metadata(bucket_id, path)
      results = @api.post(ApiPaths.paths_info_path(bucket_id), body: { paths: [path] })
      raise NotFoundError, "File not found: #{path}" if results.nil? || results.empty?

      info = results.first
      { path: info[ResponseFields::PATH], size: info[ResponseFields::SIZE], xet_hash: info[ResponseFields::XET_HASH],
        mtime: info[ResponseFields::MTIME] }
    end

    private

    def cas_eligible_error?(error)
      error.is_a?(ApiError) && error.status && error.status >= 500
    end

    # Streams a file download from the API, falling back to CAS on server error.
    #
    # @param bucket_id [String] the bucket ID
    # @param remote_path [String] remote file path
    # @param local_path [String] local destination path
    # @param cancel_token [CancelToken, nil] cooperative cancellation token
    # @return [void]
    def stream_download_to_file(bucket_id, remote_path, local_path, cancel_token: nil)
      uri = URI.parse("#{@endpoint}#{ApiPaths.resolve_path(bucket_id, remote_path)}")
      File.open(local_path, "wb") do |file|
        @api.stream_with_redirect(uri, cancel_token: cancel_token) do |chunk|
          file.write(chunk)
        end
      end
    rescue ApiError => e
      raise unless cas_eligible_error?(e)

      metadata = fetch_file_metadata(bucket_id, remote_path)
      stream_download_via_cas(bucket_id, metadata, local_path, cancel_token: cancel_token)
    end
  end
end
