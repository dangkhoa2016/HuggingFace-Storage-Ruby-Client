# frozen_string_literal: true

require "net/http"
require "uri"
require "json"
require "cgi"

require_relative "endpoints/file_endpoints"
require_relative "endpoints/directory_endpoints"
require_relative "endpoints/management_endpoints"
require_relative "auth_headers"
require_relative "request_executor"

module HuggingFaceStorage
  # HTTP client for the HuggingFace Storage REST API.
  # Provides convenience methods for GET, POST, PUT, DELETE, HEAD,
  # paginated queries, batch operations, and file downloads.
  class ApiClient
    # @return [String] default API base URL
    DEFAULT_BASE_URL = ApiPaths::BASE_URL

    # Initializes a new ApiClient.
    #
    # @param auth [Authentication, nil] authentication instance
    # @param endpoint [String, nil] custom API endpoint URL
    # @param logger [Logger, nil] logger instance
    # @param config [Configuration, nil] configuration object
    # @param transport [HTTPTransport, nil] custom HTTP transport
    # @param file_existence [FileExistence, nil] file existence checker
    # @param batch_handler [BatchHandler, nil] batch operation handler
    # @param file_downloader [FileDownloader, nil] file downloader
    def initialize(auth: nil, endpoint: nil, logger: nil, config: nil,
                   transport: nil, file_existence: nil,
                   batch_handler: nil, file_downloader: nil)
      @auth = auth
      @config = config || Configuration.default
      @endpoint = (endpoint || @config.base_url || DEFAULT_BASE_URL).chomp("/")
      @logger = logger || NullLogger.new

      @transport = transport || HTTPTransport.new(config: @config, logger: @logger)
      @file_existence = file_existence || FileExistence.new(transport: @transport, logger: @logger)

      @batch_handler = batch_handler || BatchHandler.new(logger: @logger, api_client: self)
      @pagination_service = nil
      @pagination_mutex = Mutex.new
      @file_downloader = file_downloader || FileDownloader.new(api_client: self, logger: @logger)
      @auth_headers_builder = AuthHeaders.new(auth: @auth)
      @request_executor = RequestExecutor.new(transport: @transport, config: @config, logger: @logger)
      @redirect_follower_mutex = Mutex.new
    end

    # @return [Configuration] the client configuration
    # @return [String] the API endpoint URL
    attr_reader :config, :endpoint

    # Sends a GET request and parses the JSON response.
    #
    # @param path [String] API path or full URL
    # @param params [Hash{Symbol => String}] query parameters
    # @param raw [Boolean] return raw response body instead of parsed JSON
    # @param cancel_token [CancelToken, nil] cooperative cancellation token
    # @return [Hash, Array, String, nil] parsed JSON response, raw body, or nil on empty
    def get(path, params: {}, raw: false, cancel_token: nil)
      @logger.debug { "GET #{path} params=#{params.inspect}" }
      data = request(:get, path, query: params, cancel_token: cancel_token)
      return data if raw
      return nil if data.nil? || data.empty?

      parse_json(data)
    end

    # Sends a GET request and fetches all pages via the {PaginationService}.
    #
    # @param path [String] API path
    # @param params [Hash{Symbol => String}] query parameters
    # @param cancel_token [CancelToken, nil] cooperative cancellation token
    # @param max_concurrency [Integer] max parallel page requests (default 5)
    # @param raise_on_partial_failure [Boolean] raise if any page fails (default true)
    # @return [Array<Hash>] aggregated results from all pages
    def get_paginated(path, params: {}, cancel_token: nil, max_concurrency: 5, raise_on_partial_failure: true)
      @logger.debug { "GET (paginated) #{path} params=#{params.inspect}" }
      first_uri = build_uri(path, params)
      pagination_service.fetch_all(first_uri,
                                   cancel_token: cancel_token,
                                   max_concurrency: max_concurrency,
                                   raise_on_partial_failure: raise_on_partial_failure)
    end

    # @return [PaginationService] the pagination helper for iterating over paginated API results
    def pagination_service
      @pagination_mutex.synchronize do
        @pagination_service ||= PaginationService.new(
          executor: ->(uri, request, cancel_token:) { execute_raw(uri, request, cancel_token: cancel_token) },
          logger: @logger
        )
      end
    end

    # Sends a POST request and parses the JSON response.
    #
    # @param path [String] API path
    # @param body [Hash, String, nil] request body (auto-serialized to JSON for hash)
    # @param content_type [String] Content-Type header value
    # @param cancel_token [CancelToken, nil] cooperative cancellation token
    # @return [Hash, Array, nil] parsed JSON response or nil on empty
    def post(path, body: nil, content_type: ApiPaths::CONTENT_TYPE_JSON, cancel_token: nil)
      @logger.debug { "POST #{path} content_type=#{content_type}" }
      headers = { "Content-Type" => content_type }
      request_body = if body
                       content_type == ApiPaths::CONTENT_TYPE_JSON ? JSON.generate(body) : body
                     end
      data = request(:post, path, headers: headers, body: request_body, cancel_token: cancel_token)
      return nil if data.nil? || data.empty?

      parse_json(data)
    end

    # Sends a PUT request and parses the JSON response.
    #
    # @param path [String] API path
    # @param body [String] request body
    # @param content_type [String] Content-Type header value
    # @param cancel_token [CancelToken, nil] cooperative cancellation token
    # @return [Hash, Array, nil] parsed JSON response or nil on empty
    def put(path, body:, content_type: ApiPaths::CONTENT_TYPE_OCTET, cancel_token: nil)
      data = request(:put, path, headers: { "Content-Type" => content_type }, body: body, cancel_token: cancel_token)
      return nil if data.nil? || data.empty?

      parse_json(data)
    end

    # Sends a DELETE request and parses the JSON response.
    #
    # @param path [String] API path
    # @param cancel_token [CancelToken, nil] cooperative cancellation token
    # @return [Hash, Array, nil] parsed JSON response or nil on empty
    def delete(path, cancel_token: nil)
      data = request(:delete, path, cancel_token: cancel_token)
      return nil if data.nil? || data.empty?

      parse_json(data)
    end

    # Sends a HEAD request.
    #
    # @param path [String] API path
    # @param cancel_token [CancelToken, nil] cooperative cancellation token
    # @return [Net::HTTPResponse] the HTTP response
    def head(path, cancel_token: nil)
      @transport.head(path, headers: @auth_headers_builder.call, cancel_token: cancel_token)
    end

    # Closes all open HTTP connections.
    #
    # @return [void]
    def close_all_connections
      @transport.close_all_connections
    end

    # Builds a full URI from a path and optional query parameters.
    #
    # @param path [String] API path or full URL
    # @param params [Hash{Symbol => String}] query parameters
    # @return [URI] the constructed URI
    def build_uri(path, params = {})
      url = path.start_with?("http") ? path : "#{@endpoint}#{path}"
      uri = URI.parse(url)
      uri.query = URI.encode_www_form(params) if params && !params.empty?
      uri
    end

    # Executes an HTTP request and optionally parses the JSON response.
    #
    # @param uri [URI] the request URI
    # @param request [Net::HTTPRequest] the request object
    # @param raw [Boolean] return raw response body instead of parsed JSON
    # @param cancel_token [CancelToken, nil] cooperative cancellation token
    # @return [Hash, Array, Net::HTTPResponse, nil] parsed JSON, raw response, or nil
    def execute(uri, request, raw: false, cancel_token: nil)
      @auth_headers_builder.apply(request)
      @request_executor.execute(uri, request, raw: raw, cancel_token: cancel_token)
    end

    include FileEndpoints
    include DirectoryEndpoints
    include ManagementEndpoints

    private

    # Parses JSON data, wrapping parse failures in a descriptive ApiError.
    #
    # @param data [String] raw JSON string
    # @return [Hash, Array] parsed JSON
    def parse_json(data)
      JSON.parse(data)
    rescue JSON::ParserError => e
      raise ApiError.new(
        message: "Invalid JSON response: #{e.message}",
        body: data
      )
    end

    # Sends an HTTP request via transport with authentication headers merged in.
    #
    # @param method [Symbol] HTTP method
    # @param path [String] API path
    # @param kwargs [Hash] additional arguments forwarded to transport
    # @return [String, nil] response body
    def request(method, path, **kwargs)
      kwargs[:headers] = (kwargs.delete(:headers) || {}).merge(@auth_headers_builder.call)
      @transport.request(method, path, **kwargs)
    end

    # Executes an HTTP request with auth headers applied, returning the raw response.
    #
    # @param uri [URI] the request URI
    # @param request [Net::HTTPRequest] the HTTP request
    # @param cancel_token [CancelToken, nil] cooperative cancellation token
    # @return [Net::HTTPResponse] the raw HTTP response
    def execute_raw(uri, request, cancel_token: nil)
      @auth_headers_builder.apply(request)
      @request_executor.execute_raw(uri, request, cancel_token: cancel_token)
    end
  end
end
