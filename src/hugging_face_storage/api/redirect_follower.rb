# frozen_string_literal: true

require "set"

module HuggingFaceStorage
  # Follows HTTP redirects with configurable limits, cycle detection, and streaming support.
  # @api private
  # :nodoc:
  class RedirectFollower
    # Initializes a new RedirectFollower.
    #
    # @param http_pool [HttpPool] the HTTP connection pool
    # @param header_applier [Proc, nil] callable to apply headers to redirect requests
    def initialize(http_pool:, header_applier: nil)
      @http_pool = http_pool
      @header_applier = header_applier || ->(request) {}
    end

    # Follows redirect chains up to +max_redirects+.
    #
    # @param uri [URI] the initial request URI
    # @param max_redirects [Integer] maximum redirects to follow (default 5)
    # @param cancel_token [CancelToken, nil] optional cancellation token
    # @param streaming [Boolean] whether to stream the response body
    # @param failure_message [String] error message prefix on non-OK status
    # @param cas_token [String, nil] optional CAS auth token
    # @yield [String] response body chunks when streaming
    # @return [Net::HTTPResponse, nil] the final response (nil when streaming)
    def follow_redirects(uri, max_redirects: 5, cancel_token: nil, streaming: false,
                         failure_message: "Download failed", cas_token: nil, &block)
      redirects = 0
      visited = Set.new
      loop do
        canonical = uri.to_s
        raise ApiError.new(message: "Redirect cycle detected: #{canonical}", status: 0) if visited.include?(canonical)

        visited << canonical
        response = execute_request(uri, streaming, cancel_token, cas_token) do |resp|
          code = resp.code.to_i
          new_uri = handle_redirect_or_error(resp, code, uri, redirects, max_redirects, failure_message)
          if new_uri
            redirects += 1
            uri = new_uri
            break
          end
          resp.read_body(&block) if block
          return nil
        end

        next if streaming

        new_uri = handle_redirect(response, uri, max_redirects, redirects, failure_message)
        if new_uri
          redirects += 1
          uri = new_uri
          next
        end
        return response
      end
    end

    # Builds a GET request with redirect-specific headers.
    #
    # @param uri [URI] the request URI
    # @return [Net::HTTP::Get] the request object
    def build_redirect_request(uri)
      request = Net::HTTP::Get.new(uri.request_uri)
      @header_applier.call(request)
      request
    end

    # Executes an HTTP GET request on the given URI.
    #
    # @param uri [URI] the request URI
    # @param streaming [Boolean] whether to stream the response body
    # @param cancel_token [CancelToken, nil] optional cancellation token
    # @param cas_token [String, nil] optional CAS auth token
    # @yield [Net::HTTPResponse] the response when streaming
    # @return [Net::HTTPResponse] the HTTP response
    def execute_request(uri, streaming, cancel_token, cas_token)
      cancel_token&.raise_if_cancelled!
      request = build_redirect_request(uri)
      request["Authorization"] = "Bearer #{cas_token}" if cas_token

      @http_pool.with_connection(uri) do |http|
        http.request(request) do |resp|
          next unless streaming

          yield(resp)
        end
      end
    end

    # Inspects an HTTP response and returns a redirect URI or raises on error.
    #
    # @param response [Net::HTTPResponse] the HTTP response
    # @param uri [URI] current request URI
    # @param max_redirects [Integer] maximum allowed redirects
    # @param redirects [Integer] redirects followed so far
    # @param failure_message [String] error message prefix
    # @return [URI, nil] the redirect location, or nil if the response is OK
    # @raise [ApiError] on too many redirects or non-OK status
    def handle_redirect(response, uri, max_redirects, redirects, failure_message = "Download failed")
      handle_redirect_or_error(response, response.code.to_i, uri, redirects, max_redirects, failure_message)
    end

    # Inspects the response code and either returns a redirect URI or raises.
    #
    # @param response [Net::HTTPResponse] the HTTP response
    # @param code [Integer] HTTP status code
    # @param uri [URI] current request URI (for Location resolution)
    # @param redirects [Integer] redirects followed so far
    # @param max_redirects [Integer] maximum allowed redirects
    # @param failure_message [String] error message prefix
    # @return [URI, nil] the redirect location, or nil if response is OK
    # @raise [ApiError] on too many redirects or non-OK status
    def handle_redirect_or_error(response, code, uri, redirects, max_redirects, failure_message = "Download failed")
      if ApiPaths::REDIRECT_CODES.include?(code)
        if redirects >= max_redirects
          raise ApiError.new(message: "Too many redirects", status: code,
                             body: response.body || "")
        end

        location = response["location"]
        unless location
          raise ApiError.new(message: "Redirect without Location header (HTTP #{code})", status: code,
                             body: response.body || "")
        end
        return uri.merge(location)
      end

      unless ApiPaths::Status::OK.include?(code)
        raise ApiError.new(message: "#{failure_message} (HTTP #{code}): #{uri}", status: code, body: response.body)
      end

      nil
    end
  end
end
