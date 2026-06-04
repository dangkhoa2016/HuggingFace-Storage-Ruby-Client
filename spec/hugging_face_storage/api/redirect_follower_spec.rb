# frozen_string_literal: true

require "spec_helper"

RSpec.describe HuggingFaceStorage::RedirectFollower do
  let(:http_pool) { HuggingFaceStorage::HttpPool.new(config: HuggingFaceStorage::Configuration.default, logger: null_logger) }
  let(:header_applier) { ->(request) { request["X-Test-Header"] = "applied" } }
  subject(:follower) { described_class.new(http_pool: http_pool, header_applier: header_applier) }

  describe "#build_redirect_request" do
    it "calls apply_redirect_headers to populate the request" do
      request = follower.build_redirect_request(URI.parse("https://example.com/a"))
      expect(request["X-Test-Header"]).to eq("applied")
    end
  end

  describe "#handle_redirect_or_error" do
    let(:base_uri) { URI.parse("https://example.com/a") }

    it "raises ApiError with Too many redirects when redirect limit reached" do
      resp = instance_double(Net::HTTPResponse, code: "302", body: "", :[] => "/b")
      expect do
        follower.handle_redirect_or_error(resp, 302, base_uri, 5, 5)
      end.to raise_error(HuggingFaceStorage::ApiError, /Too many redirects/)
    end

    it "raises ApiError when redirect lacks Location header" do
      resp = instance_double(Net::HTTPResponse, code: "302", body: "", :[] => nil)
      expect do
        follower.handle_redirect_or_error(resp, 302, base_uri, 0, 5)
      end.to raise_error(HuggingFaceStorage::ApiError, /Redirect without Location header/)
    end

    it "returns merged URI for valid redirect" do
      resp = instance_double(Net::HTTPResponse, code: "302", body: "", :[] => "https://cdn.example.com/x")
      result = follower.handle_redirect_or_error(resp, 302, base_uri, 0, 5)
      expect(result.to_s).to eq("https://cdn.example.com/x")
    end

    it "returns nil on 2xx success" do
      resp = instance_double(Net::HTTPResponse, code: "200", body: "ok")
      expect(follower.handle_redirect_or_error(resp, 200, base_uri, 0, 5)).to be_nil
    end

    it "raises ApiError with custom failure message on non-redirect non-success" do
      resp = instance_double(Net::HTTPResponse, code: "503", body: "busy")
      expect do
        follower.handle_redirect_or_error(resp, 503, base_uri, 0, 5, "Custom fetch failed")
      end.to raise_error(HuggingFaceStorage::ApiError, /Custom fetch failed/)
    end
  end
end
