# frozen_string_literal: true

require "spec_helper"

RSpec.describe HuggingFaceStorage::PaginationService do
  subject(:service) { described_class.new(executor: executor, logger: logger) }

  let(:logger) { null_logger }
  let(:executor) { ->(_uri, _request, cancel_token:) { simple_response(200, "[]") } }

  def simple_response(code, body)
    resp = instance_double(Net::HTTPResponse, code: code.to_s, body: body)
    allow(resp).to receive(:[]).and_return(nil)
    resp
  end

  def paged_executor(pages)
    call_count = 0
    lambda do |_uri, _request, cancel_token:|
      idx = call_count
      call_count += 1
      data = pages[idx] || []
      next_link = ("<https://huggingface.co/api/list?page=#{idx + 2}>; rel=\"next\"" if idx < pages.size - 1)
      resp = instance_double(Net::HTTPResponse, code: "200", body: JSON.generate(data))
      allow(resp).to receive(:[]).and_return(nil)
      allow(resp).to receive(:[]).with("link").and_return(next_link)
      allow(resp).to receive(:[]).with("Link").and_return(next_link)
      resp
    end
  end

  describe "#fetch_all" do
    it "returns results from a single-page response" do
      executor = lambda { |_uri, _request, cancel_token:|
        simple_response(200, JSON.generate([{ "id" => 1 }, { "id" => 2 }]))
      }
      svc = described_class.new(executor: executor, logger: logger)
      uri = URI.parse("https://huggingface.co/api/list")
      expect(svc.fetch_all(uri)).to eq([{ "id" => 1 }, { "id" => 2 }])
    end

    it "follows Link headers for multi-page sequential pagination" do
      pages = [
        [{ "id" => 1 }],
        [{ "id" => 2 }],
        [{ "id" => 3 }]
      ]
      svc = described_class.new(executor: paged_executor(pages), logger: logger)
      uri = URI.parse("https://huggingface.co/api/list")
      expect(svc.fetch_all(uri)).to eq([{ "id" => 1 }, { "id" => 2 }, { "id" => 3 }])
    end

    it "uses parallel pagination for numeric page parameters" do
      pages = Array.new(5) { |i| [{ "id" => i + 1 }] }
      executor = paged_executor(pages)
      svc = described_class.new(executor: executor, logger: logger)
      uri = URI.parse("https://huggingface.co/api/list?page=1")
      result = svc.fetch_all(uri, max_concurrency: 3)
      expect(result.size).to eq(5)
      expect(result.map { |r| r["id"] }).to contain_exactly(1, 2, 3, 4, 5)
    end

    it "respects cancel_token mid-pagination in sequential mode" do
      calls = []
      token = HuggingFaceStorage::CancelToken.new
      executor = lambda do |_uri, _request, cancel_token:|
        cancel_token&.raise_if_cancelled!
        calls << :called
        token.cancel! if calls.size == 1
        data = [{ "id" => calls.size }]
        next_link = "<https://huggingface.co/api/list?page=#{calls.size + 1}>; rel=\"next\""
        resp = instance_double(Net::HTTPResponse, code: "200", body: JSON.generate(data))
        allow(resp).to receive(:[]).and_return(nil)
        allow(resp).to receive(:[]).with("link").and_return(next_link)
        allow(resp).to receive(:[]).with("Link").and_return(next_link)
        resp
      end

      svc = described_class.new(executor: executor, logger: logger)
      uri = URI.parse("https://huggingface.co/api/list")
      expect { svc.fetch_all(uri, cancel_token: token) }.to raise_error(HuggingFaceStorage::CancelledError)
    end

    it "stops pagination when cancel_token is pre-cancelled" do
      calls = []
      token = HuggingFaceStorage::CancelToken.new
      token.cancel!
      executor = lambda do |_uri, _request, cancel_token:|
        cancel_token&.raise_if_cancelled!
        calls << :called
        resp = instance_double(Net::HTTPResponse, code: "200", body: JSON.generate([{ "id" => 1 }]))
        allow(resp).to receive(:[]).and_return(nil)
        resp
      end

      svc = described_class.new(executor: executor, logger: logger)
      uri = URI.parse("https://huggingface.co/api/list")
      expect { svc.fetch_all(uri, cancel_token: token) }.to raise_error(HuggingFaceStorage::CancelledError)
      expect(calls).to be_empty
    end

    it "handles raise_on_partial_failure: false with parallel pagination" do
      call_count = 0
      executor = lambda do |_uri, _request, cancel_token:|
        cancel_token&.raise_if_cancelled!
        call_count += 1
        raise HuggingFaceStorage::ApiError.new(message: "timeout", status: 504, body: nil) unless call_count == 1

        data = [{ "id" => 1 }]
        next_link = "<https://huggingface.co/api/list?page=2>; rel=\"next\""

        resp = instance_double(Net::HTTPResponse, code: "200", body: JSON.generate(data))
        allow(resp).to receive(:[]).and_return(nil)
        allow(resp).to receive(:[]).with("link").and_return(next_link)
        allow(resp).to receive(:[]).with("Link").and_return(next_link)
        resp
      end

      svc = described_class.new(executor: executor, logger: logger)
      uri = URI.parse("https://huggingface.co/api/list?page=1")
      result = svc.fetch_all(uri, raise_on_partial_failure: false, max_concurrency: 2)
      expect(result).to eq([{ "id" => 1 }])
    end
  end
end
