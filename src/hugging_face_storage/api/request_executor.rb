# frozen_string_literal: true

module HuggingFaceStorage
  class ApiClient
    # Executes HTTP requests with retry logic and response parsing.
    # @api private
    # :nodoc:
    class RequestExecutor
      def initialize(transport:, config:, logger:)
        @transport = transport
        @config = config
        @logger = logger
      end

      # Executes an HTTP request and parses the JSON response.
      #
      # @param uri [URI] the request URI
      # @param request [Net::HTTPRequest] the HTTP request
      # @param raw [Boolean] return raw response instead of parsing JSON
      # @param cancel_token [CancelToken, nil] cooperative cancellation token
      # @return [Hash, Array, Net::HTTPResponse, nil] parsed JSON, raw response, or nil
      def execute(uri, request, raw: false, cancel_token: nil)
        response = execute_with_retry(uri, request, cancel_token: cancel_token)
        return response if raw
        return nil if response.body.nil? || response.body.empty?

        JSON.parse(response.body)
      end

      # Executes an HTTP request with retry and returns the raw response.
      #
      # @param uri [URI] the request URI
      # @param request [Net::HTTPRequest] the HTTP request
      # @param cancel_token [CancelToken, nil] cooperative cancellation token
      # @return [Net::HTTPResponse] the raw HTTP response
      def execute_raw(uri, request, cancel_token: nil)
        execute_with_retry(uri, request, cancel_token: cancel_token)
      end

      private

      # Executes a request with retry and backoff, logging timing.
      # Follows redirects automatically for GET requests.
      #
      # @param uri [URI] the request URI
      # @param request [Net::HTTPRequest] the HTTP request
      # @param cancel_token [CancelToken, nil] cooperative cancellation token
      # @return [Net::HTTPResponse] the HTTP response
      def execute_with_retry(uri, request, cancel_token: nil)
        @transport.log_request(uri, request)
        start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        response = @transport.retry_with_backoff(@config, cancel_token: cancel_token, logger: @logger) do
          response = @transport.with_connection(uri) { |http| http.request(request) }
          @transport.log_response(uri, response)
          response
        end
        elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - start
        @logger.debug { "  #{request.method} #{uri} completed in #{elapsed.round(3)}s" }

        response = follow_redirects_if_needed(response, uri, request_method: request.method)

        handle_status(response)
        response
      end

      # Checks the response status and raises an error for non-2xx codes.
      #
      # @param response [Net::HTTPResponse] the HTTP response
      # @return [Net::HTTPResponse] the response if successful
      def handle_status(response)
        HttpErrorHandler.raise_for_status!(response)
        response
      end

      # Follows redirect responses for GET requests.
      # Non-GET requests are not redirected to avoid unsafe method changes.
      #
      # @param response [Net::HTTPResponse] the initial response
      # @param uri [URI] the original request URI
      # @param request_method [String] the HTTP method of the original request
      # @return [Net::HTTPResponse] the final response after following redirects
      # @raise [ApiError] if redirects exceed limit, Location header is missing, or final response is an error
      def follow_redirects_if_needed(response, uri, request_method: "GET")
        redirects = 0
        current_uri = uri

        while ApiPaths::REDIRECT_CODES.include?(response.code.to_i)
          break unless request_method.to_s.upcase == "GET"

          if redirects >= 5
            raise ApiError.new(
              message: "Too many redirects",
              status: response.code.to_i,
              body: response.body || ""
            )
          end

          location = response["location"]
          unless location
            raise ApiError.new(
              message: "Redirect without Location header (HTTP #{response.code})",
              status: response.code.to_i,
              body: response.body || ""
            )
          end

          current_uri = current_uri.merge(location)
          @logger.debug { "  Redirect #{response.code} -> #{current_uri}" }

          redirect_request = build_get_request(current_uri)
          @transport.log_request(current_uri, redirect_request)
          response = @transport.with_connection(current_uri) { |http| http.request(redirect_request) }
          @transport.log_response(current_uri, response)
          redirects += 1
        end

        response
      end

      # Builds a GET request for redirect following.
      #
      # @param uri [URI] the target URI
      # @return [Net::HTTP::Get] the GET request
      def build_get_request(uri)
        Net::HTTP::Get.new(uri.request_uri)
      end
    end
  end
end
