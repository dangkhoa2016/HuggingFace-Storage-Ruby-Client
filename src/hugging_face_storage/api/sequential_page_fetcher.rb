# frozen_string_literal: true

module HuggingFaceStorage
  # @api private
  # :nodoc:
  class SequentialPageFetcher
    def initialize(executor:, logger:, cancel_token:)
      @executor = executor
      @logger = logger
      @cancel_token = cancel_token
    end

    def fetch_pages(start_uri)
      # @type var results: ::Array[Hash[String, Object]]
      results = []
      uri = start_uri
      page_num = 2

      loop do
        @cancel_token&.raise_if_cancelled!
        page_request = Net::HTTP::Get.new(uri.request_uri)
        page_response = @executor.call(uri, page_request, cancel_token: @cancel_token)
        parsed = JSON.parse(page_response.body)
        results.concat(parsed)
        @logger.debug { "  Page #{page_num}: #{parsed.size} entries" }
        page_num += 1

        next_url = extract_next_link(page_response)
        break if next_url.nil?

        uri = URI.parse(next_url)
      end

      results
    end

    private

    def extract_next_link(response)
      Utils.extract_next_link(response)
    end
  end
end
