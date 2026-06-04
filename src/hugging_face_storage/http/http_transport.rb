# frozen_string_literal: true

require "net/http"
require "uri"
require "json"

module HuggingFaceStorage
  # HTTP transport layer wrapping connection pooling, retries, and request logging.
  class HTTPTransport
    # @return [String] default base URL fallback
    DEFAULT_BASE_URL = ApiPaths::BASE_URL

    # Initializes a new HTTPTransport.
    #
    # @param config [Configuration] configuration object
    # @param logger [Logger] logger instance
    def initialize(config:, logger:)
      @config = config
      @logger = logger

      @http_pool = HttpPool.new(config: @config, logger: @logger)
      @retryable = Retryable.new(logger: @logger)
      @request_logger = RequestLogger.new(logger: @logger, config: @config)
      @redirect_follower = RedirectFollower.new(http_pool: @http_pool,
                                                header_applier: ->(request) {})
    end

    # Sends an HTTP request and returns the response body.
    #
    # @param method [Symbol] HTTP method (:get, :post, :put, :delete, :head)
    # @param path [String] API path or full URL
    # @param headers [Hash{String => String}] request headers
    # @param body [String, nil] request body
    # @param cancel_token [CancelToken, nil] cooperative cancellation token
    # @param query [Hash{Symbol => String}] query parameters
    # @return [String] response body
    # @raise [ApiError] on non-2xx status
    def request(method, path, headers: {}, body: nil, cancel_token: nil, query: {})
      uri = build_uri(path, query: query)
      request_headers = build_headers(headers)

      resp = @retryable.retry_with_backoff(@config, cancel_token: cancel_token, logger: @logger) do |_retries|
        cancel_token&.raise_if_cancelled!
        http_request = build_http_request(method, uri, request_headers, body)
        @request_logger.log_request(uri, http_request)
        response = @http_pool.with_connection(uri) { |http| http.request(http_request) }
        @request_logger.log_response(uri, response)
        response
      end
      raise "unexpected nil response" if resp.nil?

      handle_status(resp)
      resp.body
    end

    # Streams an HTTP response body in chunks.
    #
    # @param method [Symbol] HTTP method
    # @param path [String] API path or full URL
    # @param headers [Hash{String => String}] request headers
    # @param body [String, nil] request body
    # @param cancel_token [CancelToken, nil] cooperative cancellation token
    # @yield [String] yields response body chunks
    # @return [void]
    def stream_download(method, path, headers: {}, body: nil, cancel_token: nil, &block)
      uri = build_uri(path)
      request_headers = build_headers(headers)

      @retryable.retry_with_backoff(@config, cancel_token: cancel_token, logger: @logger) do |_retries|
        cancel_token&.raise_if_cancelled!
        http_request = build_http_request(method, uri, request_headers, body)
        @request_logger.log_request(uri, http_request)
        @redirect_follower.follow_redirects(uri, http_request, cancel_token: cancel_token, streaming: true, &block)
        nil
      end
    end

    # Sends a HEAD request.
    #
    # @param path [String] API path or full URL
    # @param headers [Hash{String => String}] request headers
    # @param cancel_token [CancelToken, nil] cooperative cancellation token
    # @return [Net::HTTPResponse] the HTTP response
    def head(path, headers: {}, cancel_token: nil)
      uri = build_uri(path)
      request_headers = build_headers(headers)

      resp = @retryable.retry_with_backoff(@config, cancel_token: cancel_token, logger: @logger) do |_retries|
        cancel_token&.raise_if_cancelled!
        http_request = Net::HTTP::Head.new(uri.request_uri, request_headers)
        @request_logger.log_request(uri, http_request)
        response = @http_pool.with_connection(uri) { |http| http.request(http_request) }
        @request_logger.log_response(uri, response)
        response
      end
      raise "unexpected nil response" if resp.nil?

      handle_status(resp)
      resp
    end

    # Closes all open HTTP connections in the pool.
    #
    # @return [void]
    def close_all_connections
      @http_pool.close_all_connections
    end

    # Acquires a pooled HTTP connection and yields it.
    #
    # @param uri [URI] the target URI
    # @yield [Net::HTTP] an active HTTP connection
    # @return [Object] result of the block
    def with_connection(uri, &block)
      @http_pool.with_connection(uri, &block)
    end

    # Retries a block with exponential backoff.
    #
    # @yield block to retry
    # @return [Object] block result
    def retry_with_backoff(...)
      @retryable.retry_with_backoff(...)
    end

    # Logs an HTTP request.
    #
    # @return [void]
    def log_request(...)
      @request_logger.log_request(...)
    end

    # Logs an HTTP response.
    #
    # @return [void]
    def log_response(...)
      @request_logger.log_response(...)
    end

    # Builds a RedirectFollower.
    #
    # @param header_applier [Proc, nil] callable to apply headers to redirect requests
    # @return [RedirectFollower] a new redirect follower
    def build_redirect_follower(header_applier: nil)
      RedirectFollower.new(http_pool: @http_pool,
                           header_applier: header_applier || ->(request) {})
    end

    private

    # Builds a full URI from a path and optional query parameters.
    #
    # @param path [String] API path or full URL
    # @param query [Hash{Symbol => String}] query parameters
    # @return [URI] the constructed URI
    def build_uri(path, query: {})
      if path.start_with?("http://", "https://")
        uri = URI(path)
      else
        base = @config.base_url || DEFAULT_BASE_URL
        uri = URI("#{base}#{path}")
      end
      uri.query = URI.encode_www_form(query) unless query.empty?
      uri
    end

    # Builds request headers with a default Content-Type if not already set.
    #
    # @param extra [Hash{String => String}] additional headers
    # @return [Hash{String => String}] merged headers
    def build_headers(extra = {})
      { "Content-Type" => "application/json" }.merge(extra)
    end

    # Builds the appropriate Net::HTTP request object for the given method.
    #
    # @param method [Symbol] HTTP method (:get, :post, :put, :delete, :head)
    # @param uri [URI] the request URI
    # @param headers [Hash{String => String}] request headers
    # @param body [String, nil] request body
    # @return [Net::HTTPRequest] the constructed HTTP request
    def build_http_request(method, uri, headers, body)
      request = case method
                when :get    then Net::HTTP::Get.new(uri.request_uri, headers)
                when :post   then Net::HTTP::Post.new(uri.request_uri, headers)
                when :put    then Net::HTTP::Put.new(uri.request_uri, headers)
                when :delete then Net::HTTP::Delete.new(uri.request_uri, headers)
                when :head   then Net::HTTP::Head.new(uri.request_uri, headers)
                else raise ArgumentError, "Unknown HTTP method: #{method}"
                end
      request.body = body if body
      request
    end

    # Checks the response status and raises an error for non-2xx codes.
    #
    # @param response [Net::HTTPResponse] the HTTP response
    # @return [void]
    def handle_status(response)
      HttpErrorHandler.raise_for_status!(response)
    end
  end
end
