# frozen_string_literal: true

require "spec_helper"

RSpec.describe HuggingFaceStorage::ApiClient do
  include_context "with null logger"
  include_context "with api client setup"

  describe "#get_paginated" do
    it "collects results from a single page" do
      stub_request(:get, "#{base}/api/list?page=1")
        .to_return(status: 200, body: '[{"id":1},{"id":2}]',
                   headers: { "Content-Type" => "application/json" })

      results = client.get_paginated("/api/list", params: { page: "1" })
      expect(results.size).to eq(2)
    end

    it "follows Link header pagination" do
      stub_request(:get, "#{base}/api/list")
        .to_return(
          status: 200,
          body: '[{"id":1}]',
          headers: {
            "Content-Type" => "application/json",
            "Link" => "<#{base}/api/list?page=2>; rel=\"next\""
          }
        )

      stub_request(:get, "#{base}/api/list?page=2")
        .to_return(
          status: 200,
          body: '[{"id":2}]',
          headers: { "Content-Type" => "application/json" }
        )

      results = client.get_paginated("/api/list")
      expect(results.size).to eq(2)
      expect(results.map { |r| r["id"] }).to eq([1, 2])
    end

    it "follows three sequential pages when param detection fails" do
      stub_request(:get, "#{base}/api/list")
        .to_return(
          status: 200,
          body: '[{"id":1}]',
          headers: {
            "Content-Type" => "application/json",
            "Link" => "<#{base}/api/list?page=2>; rel=\"next\""
          }
        )

      stub_request(:get, "#{base}/api/list?page=2")
        .to_return(
          status: 200,
          body: '[{"id":2}]',
          headers: {
            "Content-Type" => "application/json",
            "Link" => "<#{base}/api/list?page=3>; rel=\"next\""
          }
        )

      stub_request(:get, "#{base}/api/list?page=3")
        .to_return(
          status: 200,
          body: '[{"id":3}]',
          headers: { "Content-Type" => "application/json" }
        )

      results = client.get_paginated("/api/list")
      expect(results.size).to eq(3)
      expect(results.map { |r| r["id"] }).to eq([1, 2, 3])
    end

    it "fetches pages in parallel for numeric pagination" do
      stub_request(:get, "#{base}/api/list?page=1")
        .to_return(
          status: 200,
          body: '[{"id":1}]',
          headers: {
            "Content-Type" => "application/json",
            "Link" => "<#{base}/api/list?page=2>; rel=\"next\""
          }
        )

      stub_request(:get, "#{base}/api/list?page=2")
        .to_return(
          status: 200,
          body: '[{"id":2}]',
          headers: {
            "Content-Type" => "application/json",
            "Link" => "<#{base}/api/list?page=3>; rel=\"next\""
          }
        )

      stub_request(:get, "#{base}/api/list?page=3")
        .to_return(
          status: 200,
          body: '[{"id":3}]',
          headers: { "Content-Type" => "application/json" }
        )

      stub_request(:get, "#{base}/api/list?page=4")
        .to_return(status: 200, body: "[]",
                   headers: { "Content-Type" => "application/json" })

      stub_request(:get, "#{base}/api/list?page=5")
        .to_return(status: 200, body: "[]",
                   headers: { "Content-Type" => "application/json" })

      stub_request(:get, "#{base}/api/list?page=6")
        .to_return(status: 200, body: "[]",
                   headers: { "Content-Type" => "application/json" })

      results = client.get_paginated("/api/list", params: { page: "1" }, max_concurrency: 5)
      expect(results.size).to eq(3)
      expect(results.map { |r| r["id"] }).to contain_exactly(1, 2, 3)
    end

    it "fetches pages in multiple parallel batches when needed" do
      (1..5).each do |n|
        headers = { "Content-Type" => "application/json" }
        headers["Link"] = "<#{base}/api/list?page=#{n + 1}>; rel=\"next\"" if n < 5
        stub_request(:get, "#{base}/api/list?page=#{n}")
          .to_return(status: 200, body: "[{\"id\":#{n}}]", headers: headers)
      end

      results = client.get_paginated("/api/list", params: { page: "1" }, max_concurrency: 2)
      expect(results.size).to eq(5)
      expect(results.map { |r| r["id"] }).to contain_exactly(1, 2, 3, 4, 5)
    end

    it "raises composite error when parallel fetch threads encounter errors" do
      stub_request(:get, "#{base}/api/list?page=1")
        .to_return(
          status: 200, body: '[{"id":1}]',
          headers: {
            "Content-Type" => "application/json",
            "Link" => "<#{base}/api/list?page=2>; rel=\"next\""
          }
        )

      stub_request(:get, "#{base}/api/list?page=2")
        .to_return(status: 503, body: "service unavailable")

      (3..6).each do |n|
        stub_request(:get, "#{base}/api/list?page=#{n}")
          .to_return(status: 200, body: "[]",
                     headers: { "Content-Type" => "application/json" })
      end

      expect {
        client.get_paginated("/api/list", params: { page: "1" }, max_concurrency: 5)
      }.to raise_error(HuggingFaceStorage::PaginationError) { |e|
        expect(e.pages_failed).to eq([2])
      }
    end

    it "returns partial results with a warning when raise_on_partial_failure: false" do
      stub_request(:get, "#{base}/api/list?page=1")
        .to_return(
          status: 200, body: '[{"id":1}]',
          headers: {
            "Content-Type" => "application/json",
            "Link" => "<#{base}/api/list?page=2>; rel=\"next\""
          }
        )

      stub_request(:get, "#{base}/api/list?page=2")
        .to_return(status: 503, body: "service unavailable")

      (3..6).each do |n|
        stub_request(:get, "#{base}/api/list?page=#{n}")
          .to_return(status: 200, body: "[]",
                     headers: { "Content-Type" => "application/json" })
      end

      results = client.get_paginated("/api/list", params: { page: "1" }, max_concurrency: 5,
                                                  raise_on_partial_failure: false)
      expect(results).to eq([{ "id" => 1 }])
    end

    it "PaginationError lists every failed page number across the parallel batch" do
      stub_request(:get, "#{base}/api/list?page=1")
        .to_return(
          status: 200, body: '[{"id":1}]',
          headers: {
            "Content-Type" => "application/json",
            "Link" => "<#{base}/api/list?page=2>; rel=\"next\""
          }
        )

      [2, 3, 4].each do |n|
        stub_request(:get, "#{base}/api/list?page=#{n}")
          .to_return(status: 503, body: "service unavailable")
      end

      (5..6).each do |n|
        stub_request(:get, "#{base}/api/list?page=#{n}")
          .to_return(status: 200, body: "[]",
                     headers: { "Content-Type" => "application/json" })
      end

      expect {
        client.get_paginated("/api/list", params: { page: "1" }, max_concurrency: 3)
      }.to raise_error(HuggingFaceStorage::PaginationError) { |e|
        expect(e.pages_failed).to contain_exactly(2, 3, 4)
        expect(e.errors.size).to eq(3)
      }
    end

    it "caps pagination concurrency at MAX_PAGINATION_CONCURRENCY" do
      stub_request(:get, "#{base}/api/list?page=1")
        .to_return(status: 200, body: '[{"id":1}]',
                   headers: { "Content-Type" => "application/json",
                              "Link" => "<#{base}/api/list?page=2>; rel=\"next\"" })
      (2..22).each do |n|
        stub_request(:get, "#{base}/api/list?page=#{n}")
          .to_return(status: 200, body: "[]",
                     headers: { "Content-Type" => "application/json" })
      end

      out = StringIO.new
      capped_logger = HuggingFaceStorage::HFLogger.new(level: :debug, output: out, format: :default)
      capped_client = described_class.new(auth: auth, logger: capped_logger)
      results = capped_client.get_paginated("/api/list", params: { page: "1" }, max_concurrency: 100)
      expect(results).to eq([{ "id" => 1 }])
      expect(out.string).to include("Capping pagination concurrency")
    end
  end
end
