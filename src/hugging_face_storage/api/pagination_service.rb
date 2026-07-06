# frozen_string_literal: true

module HuggingFaceStorage
  # Fetches all pages of a paginated API response with parallel support.
  # @api private
  # :nodoc:
  class PaginationService
    MAX_CONCURRENCY = 20

    def initialize(executor:, logger: nil)
      @executor = executor
      @logger = logger || NullLogger.new
    end

    def fetch_all(first_uri, cancel_token: nil, max_concurrency: 5, raise_on_partial_failure: true)
      request = Net::HTTP::Get.new(first_uri.request_uri)
      response = @executor.call(first_uri, request, cancel_token: cancel_token)
      results = JSON.parse(response.body)
      @logger.debug { "  Page 1: #{results.size} entries" }

      next_url_str = extract_next_link(response)
      return results if next_url_str.nil?

      next_uri = URI.parse(next_url_str)
      param, base = PageParameterDetector.new.detect(first_uri, next_uri)
      base_page = base || 0

      extra = if param
                ParallelPageFetcher.new(executor: @executor, logger: @logger, cancel_token: cancel_token)
                                   .fetch_pages(first_uri, param, base_page,
                                                max_concurrency: max_concurrency,
                                                raise_on_partial_failure: raise_on_partial_failure)
              else
                SequentialPageFetcher.new(executor: @executor, logger: @logger, cancel_token: cancel_token)
                                     .fetch_pages(next_uri)
              end

      results.concat(extra)
      @logger.debug { "  Total: #{results.size} entries" }
      results
    end

    private

    def extract_next_link(response)
      Utils.extract_next_link(response)
    end
  end
end
