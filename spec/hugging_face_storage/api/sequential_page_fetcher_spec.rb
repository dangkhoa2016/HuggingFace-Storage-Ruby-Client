# frozen_string_literal: true

require "spec_helper"

RSpec.describe HuggingFaceStorage::SequentialPageFetcher do
  subject(:fetcher) { described_class.new(executor: executor, logger: logger, cancel_token: cancel_token) }

  let(:executor) { proc { |_uri, _req, cancel_token:| http_response } }
  let(:logger) { instance_double(HuggingFaceStorage::HFLogger, debug: nil) }
  let(:cancel_token) { HuggingFaceStorage::CancelToken.new }

  let(:data_page1) { [{ "id" => 1 }, { "id" => 2 }] }
  let(:data_page2) { [{ "id" => 3 }] }
  let(:data_page3) { [] }

  def http_response(body, link_header: nil)
    headers = {}
    headers["link"] = link_header if link_header
    instance_double(Net::HTTPResponse,
      body: JSON.generate(body),
      code: "200",
      :[] => headers["link"]
    ).tap do |resp|
      allow(resp).to receive(:[]).with("link").and_return(headers["link"])
      allow(resp).to receive(:[]).with("Link").and_return(nil)
    end
  end

  describe "#fetch_pages" do
    it "returns results from a single page" do
      allow(executor).to receive(:call).and_return(http_response(data_page1))

      results = fetcher.fetch_pages(URI("https://huggingface.co/api/test"))

      expect(results).to eq(data_page1)
    end

    it "follows Link header to fetch multiple pages" do
      next_url = "https://huggingface.co/api/test?page=2"
      allow(executor).to receive(:call).and_return(
        http_response(data_page1, link_header: "<#{next_url}>; rel=\"next\""),
        http_response(data_page2, link_header: nil)
      )

      results = fetcher.fetch_pages(URI("https://huggingface.co/api/test"))

      expect(results).to eq(data_page1 + data_page2)
    end

    it "follows multiple pages until no next link" do
      url2 = "https://huggingface.co/api/test?page=2"
      url3 = "https://huggingface.co/api/test?page=3"
      allow(executor).to receive(:call).and_return(
        http_response(data_page1, link_header: "<#{url2}>; rel=\"next\""),
        http_response(data_page2, link_header: "<#{url3}>; rel=\"next\""),
        http_response(data_page3, link_header: nil)
      )

      results = fetcher.fetch_pages(URI("https://huggingface.co/api/test"))

      expect(results).to eq(data_page1 + data_page2 + data_page3)
    end

    it "raises CancelledError when token is cancelled" do
      next_url = "https://huggingface.co/api/test?page=2"
      call_count = 0
      allow(executor).to receive(:call) do
        call_count += 1
        cancel_token.cancel! if call_count == 1
        http_response(data_page1, link_header: "<#{next_url}>; rel=\"next\"")
      end

      expect { fetcher.fetch_pages(URI("https://huggingface.co/api/test")) }
        .to raise_error(HuggingFaceStorage::CancelledError)
    end

    it "works without a cancel token" do
      fetcher = described_class.new(executor: executor, logger: logger, cancel_token: nil)
      allow(executor).to receive(:call).and_return(http_response(data_page1))

      results = fetcher.fetch_pages(URI("https://huggingface.co/api/test"))

      expect(results).to eq(data_page1)
    end
  end

  describe "#extract_next_link" do
    it "returns the URL from a Link header with rel=\"next\"" do
      resp = http_response([], link_header: '<https://api.example.com/next>; rel="next"')
      expect(fetcher.send(:extract_next_link, resp)).to eq("https://api.example.com/next")
    end

    it "returns nil when there is no Link header" do
      resp = http_response([])
      expect(fetcher.send(:extract_next_link, resp)).to be_nil
    end

    it "returns nil when Link header has no rel=\"next\"" do
      resp = http_response([], link_header: '<https://api.example.com/prev>; rel="prev"')
      expect(fetcher.send(:extract_next_link, resp)).to be_nil
    end
  end
end
