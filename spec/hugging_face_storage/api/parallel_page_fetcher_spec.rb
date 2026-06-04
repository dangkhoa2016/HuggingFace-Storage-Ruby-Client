# frozen_string_literal: true

require "spec_helper"
require "cgi"

RSpec.describe HuggingFaceStorage::ParallelPageFetcher do
  subject(:fetcher) { described_class.new(executor: executor, logger: logger, cancel_token: cancel_token) }

  let(:executor) { proc { |_uri, _req, cancel_token:| http_response([]) } }
  let(:logger) { instance_double(HuggingFaceStorage::HFLogger, debug: nil, warn: nil) }
  let(:cancel_token) { HuggingFaceStorage::CancelToken.new }
  let(:base_uri) { URI("https://huggingface.co/api/test?page=1") }

  def http_response(body, link_header: nil)
    headers = {}
    headers["link"] = link_header if link_header
    instance_double(Net::HTTPResponse,
      body: JSON.generate(body),
      code: "200",
      :[] => nil
    ).tap do |resp|
      allow(resp).to receive(:[]).with("link").and_return(headers["link"])
      allow(resp).to receive(:[]).with("Link").and_return(nil)
    end
  end

  describe "#fetch_pages" do
    it "returns empty results when all pages are empty" do
      results = fetcher.fetch_pages(base_uri, "page", 1)
      expect(results).to eq([])
    end

    it "fetches batch pages by query parameter" do
      seen_pages = []
      allow(executor).to receive(:call) do |uri, _req, cancel_token:|
        seen_pages << uri.query
        http_response([{ "page" => uri.query }])
      end

      results = fetcher.fetch_pages(base_uri, "page", 1, max_concurrency: 3)
      expect(results.size).to eq(3)
      expect(results.map { |r| r["page"] }).to contain_exactly("page=2", "page=3", "page=4")
    end

    it "fetches subsequent batches when next_link is present" do
      allow(executor).to receive(:call) do |uri, _req, cancel_token:|
        page_num = URI.decode_www_form(uri.query).group_by(&:first).transform_values { |v|
          v.map(&:last)
        }["page"].first.to_i
        has_next = page_num < 4
        http_response([{ "page" => page_num }],
link_header: has_next ? "<https://huggingface.co/api/test?page=#{page_num + 2}>; rel=\"next\"" : nil)
      end

      results = fetcher.fetch_pages(base_uri, "page", 1, max_concurrency: 2)
      expect(results.map { |r| r["page"] }).to contain_exactly(2, 3, 4, 5)
    end

    it "raises PaginationError when pages fail and raise_on_partial_failure is true" do
      allow(executor).to receive(:call).and_raise(Net::OpenTimeout, "connection timed out")

      expect do
        fetcher.fetch_pages(base_uri, "page", 1, max_concurrency: 2)
      end.to raise_error(HuggingFaceStorage::PaginationError)
    end

    it "returns partial results when raise_on_partial_failure is false" do
      call_count = 0
      mutex = Mutex.new
      allow(executor).to receive(:call) do
        should_fail = mutex.synchronize { call_count += 1; call_count == 2 }
        raise Net::OpenTimeout, "timeout" if should_fail

        http_response([{ "id" => 1 }])
      end

      results = fetcher.fetch_pages(base_uri, "page", 1, max_concurrency: 2, raise_on_partial_failure: false)
      expect(results).to eq([{ "id" => 1 }])
    end

    it "caps concurrency at MAX_CONCURRENCY" do
      allow(executor).to receive(:call).and_return(http_response([]))
      results = fetcher.fetch_pages(base_uri, "page", 1, max_concurrency: 100)
      expect(results).to eq([])
    end

    it "raises CancelledError when token is cancelled between batches" do
      allow(executor).to receive(:call).and_return(
        http_response([{ "id" => 1 }], link_header: "<https://huggingface.co/api/test?page=5>; rel=\"next\""),
        http_response([{ "id" => 2 }], link_header: "<https://huggingface.co/api/test?page=5>; rel=\"next\"")
      )

      cancel_token.cancel!

      expect { fetcher.fetch_pages(base_uri, "page", 1, max_concurrency: 2) }
        .to raise_error(HuggingFaceStorage::CancelledError)
    end

    it "works without a cancel token" do
      fetcher = described_class.new(executor: executor, logger: logger, cancel_token: nil)
      allow(executor).to receive(:call).and_return(http_response([{ "id" => 1 }]))
      results = fetcher.fetch_pages(base_uri, "page", 1, max_concurrency: 1)
      expect(results).to eq([{ "id" => 1 }])
    end
  end

  describe "#extract_next_link" do
    it "returns the URL from a Link header" do
      resp = http_response([], link_header: '<https://api.example.com/next>; rel="next"')
      expect(fetcher.send(:extract_next_link, resp)).to eq("https://api.example.com/next")
    end

    it "returns nil when no Link header" do
      expect(fetcher.send(:extract_next_link, http_response([]))).to be_nil
    end

    it "returns nil when no rel=next" do
      resp = http_response([], link_header: '<https://api.example.com/prev>; rel="prev"')
      expect(fetcher.send(:extract_next_link, resp)).to be_nil
    end
  end
end
