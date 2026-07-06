# frozen_string_literal: true

module HuggingFaceStorage
  # Client module for uploading data to a Content-Addressable Storage (CAS) server.
  module CasClient
    private

    # Returns the metrics registry.
    #
    # @return [MetricsRegistry] the metrics registry
    def metrics_registry
      @metrics_registry || ::HuggingFaceStorage::NullMetricsRegistry.instance
    end

    # Uploads a xorb to the CAS server.
    #
    # @param cas_url [String] the CAS server URL
    # @param token [String] the auth token
    # @param xorb_hash [String] the xorb hash
    # @param xorb_data [String] the xorb binary data
    # @param cancel_token [CancelToken, nil] optional cancellation token
    def upload_xorb(cas_url, token, xorb_hash, xorb_data, cancel_token: nil)
      hex = Utils.hash_to_hex(xorb_hash)
      @logger.debug { "Upload xorb: #{hex} (#{xorb_data.bytesize} bytes)" }
      cas_post("#{cas_url}/v1/xorbs/default/#{hex}", token, xorb_data, "Xorb", cancel_token: cancel_token)
      metrics_registry.increment(:xorbs)
      metrics_registry.increment(:bytes_uploaded, xorb_data.bytesize)
    end

    # Uploads a shard to the CAS server.
    #
    # @param cas_url [String] the CAS server URL
    # @param token [String] the auth token
    # @param shard_data [String] the shard binary data
    # @param cancel_token [CancelToken, nil] optional cancellation token
    def upload_shard(cas_url, token, shard_data, cancel_token: nil)
      @logger.debug { "Upload shard (#{shard_data.bytesize} bytes)" }
      cas_post("#{cas_url}/v1/shards", token, shard_data, "Shard", cancel_token: cancel_token)
      metrics_registry.increment(:shards)
      metrics_registry.increment(:bytes_uploaded, shard_data.bytesize)
    end

    # POSTs data to the CAS server with retry and cancellation support.
    #
    # @param url [String] the full CAS URL
    # @param token [String] the auth token
    # @param data [String] the binary data
    # @param label [String] label for error messages
    # @param cancel_token [CancelToken, nil] optional cancellation token
    # @raise [ApiError] if the upload fails
    def cas_post(url, token, data, label, cancel_token: nil)
      cancel_token&.raise_if_cancelled!
      uri = URI.parse(url)
      config = @config || Configuration.default
      pool = @transport&.http_pool || @http_pool
      rt = @transport&.retryable || @retryable

      resp = perform_cas_post(uri, token, data, pool, rt, config, cancel_token)
      handle_cas_response(resp, label)
    end

    def perform_cas_post(uri, token, data, pool, retryable, config, cancel_token)
      retryable.retry_with_backoff(config, cancel_token: cancel_token, logger: @logger) do |_retries|
        req = Net::HTTP::Post.new(uri.request_uri)
        req["Authorization"] = "Bearer #{token}"
        req["Content-Type"] = ApiPaths::CONTENT_TYPE_OCTET
        req.body = data
        pool.with_connection(uri) { |http| http.request(req) }
      end
    end

    def handle_cas_response(resp, label)
      return if ApiPaths::Status::OK.include?(resp.code.to_i)

      @logger.error("#{label} upload failed (HTTP #{resp.code}): #{resp.body&.[](0..200)}")
      raise ApiError.new(message: "#{label} upload failed (HTTP #{resp.code}): #{resp.body}",
                         status: resp.code.to_i, body: resp.body)
    end
  end
end
