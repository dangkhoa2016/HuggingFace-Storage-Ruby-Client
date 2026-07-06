# frozen_string_literal: true

require "uri"

module HuggingFaceStorage
  # @api private
  # :nodoc:
  class ParallelPageFetcher
    MAX_CONCURRENCY = 20

    def initialize(executor:, logger:, cancel_token:)
      @executor = executor
      @logger = logger
      @cancel_token = cancel_token
    end

    def fetch_pages(base_uri, page_param, base_page, max_concurrency: 5, raise_on_partial_failure: true)
      next_page = base_page + 1
      effective_concurrency = cap_concurrency(max_concurrency)

      results = []
      loop do
        @cancel_token&.raise_if_cancelled!

        uris = build_uris(base_uri, page_param, next_page, effective_concurrency)
        batch_results, failed_pages = fetch_batch(uris, next_page)

        batch_results.sort_by! { |r| r[:index] }
        batch_results.each { |r| results.concat(r[:data]) }
        log_batch_results(batch_results, next_page)

        break unless handle_failed_pages?(failed_pages, raise_on_partial_failure, effective_concurrency)

        break unless more_pages?(batch_results)

        next_page += effective_concurrency
      end

      results
    end

    private

    def cap_concurrency(max_concurrency)
      effective = max_concurrency.clamp(1, MAX_CONCURRENCY)
      if max_concurrency > MAX_CONCURRENCY
        @logger.debug do
          "  Capping pagination concurrency from #{max_concurrency} to #{MAX_CONCURRENCY}"
        end
      end
      effective
    end

    def handle_failed_pages?(failed_pages, raise_on_partial_failure, effective_concurrency)
      return true if failed_pages.empty?

      if raise_on_partial_failure
        raise PaginationError.new(failed_pages.map { |f| f[:page] }, failed_pages.map { |f|
          f[:error]
        })
      end

      @logger.warn("  Partial pagination: #{failed_pages.size}/#{effective_concurrency} page(s) failed")
      false
    end

    def more_pages?(batch_results)
      batch_results.any? { |r| !r[:data].empty? } && batch_results.last[:next_link]
    end

    def log_batch_results(batch_results, next_page)
      @logger.debug { "  Batch after page #{next_page - 1}: #{batch_results.sum { |r| r[:data].size }} entries" }
    end

    def build_uris(base_uri, page_param, next_page, count)
      count.times.map do |i|
        params = parse_query(base_uri.query)
        params[page_param] = [(next_page + i).to_s]
        new_uri = base_uri.dup
        new_uri.query = URI.encode_www_form(params)
        new_uri
      end
    end

    def parse_query(query)
      URI.decode_www_form(query || "").group_by(&:first).transform_values { |v| v.map(&:last) }
    end

    def fetch_batch(uris, next_page)
      # @type var batch_results: ::Array[::Hash[Symbol, untyped]]
      batch_results = []
      # @type var failed_pages: ::Array[::Hash[Symbol, untyped]]
      failed_pages = []
      mutex = Mutex.new

      threads = uris.each_with_index.map do |uri, idx|
        Thread.new do
          @cancel_token&.raise_if_cancelled!
          page_request = Net::HTTP::Get.new(uri.request_uri)
          page_response = @executor.call(uri, page_request, cancel_token: @cancel_token)
          parsed = JSON.parse(page_response.body)
          next_link = extract_next_link(page_response)
          mutex.synchronize { batch_results << { index: idx, data: parsed, next_link: next_link } }
        rescue StandardError => e
          pn = next_page + idx
          @logger.warn("Page #{pn} fetch failed: #{e.message}")
          mutex.synchronize { failed_pages << { page: pn, error: e } }
        end
      end
      threads.each(&:join)

      [batch_results, failed_pages]
    end

    def extract_next_link(response)
      Utils.extract_next_link(response)
    end
  end
end
