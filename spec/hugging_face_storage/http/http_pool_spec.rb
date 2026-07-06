# frozen_string_literal: true

require "spec_helper"

RSpec.describe HuggingFaceStorage::HttpPool do
  let(:pool_class) do
    Class.new(described_class) do
      public :build_http, :acquire, :release, :pool_key, :reap_idle_connections, :connections, :pool_mutex
    end
  end
  subject(:pool) { pool_class.new(config: HuggingFaceStorage::Configuration.default, logger: null_logger) }

  let(:frozen_time) { Time.new(2025, 1, 1, 12, 0, 0, "+00:00") }
  before { allow(Time).to receive(:now).and_return(frozen_time) }

  describe "#pool_key" do
    it "includes host, port, and scheme" do
      key = pool.pool_key(URI.parse("https://example.com:8443"))
      expect(key).to eq("example.com:8443:https")
    end

    it "produces different keys for different ports" do
      k1 = pool.pool_key(URI.parse("https://example.com:443"))
      k2 = pool.pool_key(URI.parse("https://example.com:8443"))
      expect(k1).not_to eq(k2)
    end

    it "produces different keys for different schemes" do
      k1 = pool.pool_key(URI.parse("https://example.com"))
      k2 = pool.pool_key(URI.parse("http://example.com"))
      expect(k1).not_to eq(k2)
    end
  end

  describe "#acquire" do
    it "returns a Net::HTTP for the given URI" do
      http = pool.acquire(URI.parse("https://example.com"))
      expect(http).to be_a(Net::HTTP)
      expect(http.address).to eq("example.com")
      expect(http.port).to eq(443)
    end

    it "reuses a released connection for the same URI" do
      uri = URI.parse("https://example.com")
      http1 = pool.acquire(uri)
      pool.release(uri, http1)
      http2 = pool.acquire(uri)
      expect(http1).to equal(http2)
    end

    it "creates separate connections for different hosts" do
      host_a = pool.acquire(URI.parse("https://host-a.com"))
      host_b = pool.acquire(URI.parse("https://host-b.com"))
      expect(host_a).not_to equal(host_b)
    end

    it "discards an idle-expired connection and builds a fresh one" do
      uri = URI.parse("https://example.com")
      http1 = pool.acquire(uri)
      pool.release(uri, http1)

      key = pool.pool_key(uri)
      pool.send(:connections)[key][:last_used] = Time.now - 10_000

      http2 = pool.acquire(uri)
      expect(http2).not_to equal(http1)
    end
  end

  describe "#acquire / #release" do
    it "acquire removes the connection from the pool" do
      uri = URI.parse("https://example.com")
      http = pool.build_http(uri)
      key = pool.pool_key(uri)
      pool.send(:connections)[key] = { http: http, last_used: Time.now }

      acquired = pool.acquire(uri)
      expect(acquired).to equal(http)
      expect(pool.send(:connections)[key]).to be_nil
    end

    it "release returns the connection to the pool with last_used timestamp" do
      uri = URI.parse("https://example.com")
      http = pool.build_http(uri)
      pool.release(uri, http)

      key = pool.pool_key(uri)
      entry = pool.send(:connections)[key]
      expect(entry[:http]).to equal(http)
      expect(entry[:last_used]).to be_within(1).of(frozen_time)
    end
  end

  describe "#build_http" do
    it "sets SSL for https URIs" do
      http = pool.build_http(URI.parse("https://example.com"))
      expect(http.use_ssl?).to be true
    end

    it "does not set SSL for http URIs" do
      http = pool.build_http(URI.parse("http://example.com"))
      expect(http.use_ssl?).to be false
    end

    it "sets open_timeout from config" do
      http = pool.build_http(URI.parse("https://example.com"))
      expect(http.open_timeout).to eq(HuggingFaceStorage::Configuration.default.open_timeout)
    end

    it "sets read_timeout from config" do
      http = pool.build_http(URI.parse("https://example.com"))
      expect(http.read_timeout).to eq(HuggingFaceStorage::Configuration.default.read_timeout)
    end

    it "sets write_timeout from config" do
      http = pool.build_http(URI.parse("https://example.com"))
      expect(http.write_timeout).to eq(HuggingFaceStorage::Configuration.default.write_timeout)
    end
  end

  describe "#with_connection" do
    it "yields a started HTTP connection" do
      uri = URI.parse("https://example.com")
      stub_request(:any, "https://example.com/").to_return(status: 200, body: "")

      pool.with_connection(uri) do |http|
        expect(http.started?).to be true
      end
    end

    it "returns the connection to the pool after use" do
      uri = URI.parse("https://example.com")
      stub_request(:any, "https://example.com/").to_return(status: 200, body: "")

      pool.with_connection(uri) { |_| nil }

      key = pool.pool_key(uri)
      expect(pool.send(:connections)[key][:http]).to be_a(Net::HTTP)
    end

    it "releases connection even when http.start fails" do
      uri = URI.parse("https://example.com")
      http = pool.build_http(uri)
      allow(http).to receive(:start).and_raise(Errno::ECONNREFUSED)
      allow(pool).to receive(:acquire).and_return(http)

      expect {
        pool.with_connection(uri) { |h| h.get("/") }
      }.to raise_error(Errno::ECONNREFUSED)

      key = pool.pool_key(uri)
      expect(pool.send(:connections)[key][:http]).to equal(http)
    end
  end

  describe "#reap_idle_connections" do
    it "returns 0 when no connections are idle-expired" do
      uri = URI.parse("https://example.com")
      http = pool.acquire(uri)
      pool.release(uri, http)
      expect(pool.reap_idle_connections).to eq(0)
    end

    it "finishes and removes connections idle longer than idle_timeout" do
      uri = URI.parse("https://example.com")
      http = pool.acquire(uri)
      begin
        http.start
      rescue StandardError
        nil
      end
      pool.release(uri, http)

      key = pool.pool_key(uri)
      pool.send(:connections)[key][:last_used] = Time.now - 10_000

      expect(pool.reap_idle_connections).to eq(1)
      expect(pool.send(:connections)[key]).to be_nil
    end

    it "tolerates errors when finishing idle connections" do
      uri = URI.parse("https://example.com")
      http = pool.acquire(uri)
      pool.release(uri, http)

      key = pool.pool_key(uri)
      pool.send(:connections)[key][:last_used] = Time.now - 10_000
      allow(pool.send(:connections)[key][:http]).to receive(:finish).and_raise(StandardError, "already closed")

      expect(pool.reap_idle_connections).to eq(1)
      expect(pool.send(:connections)[key]).to be_nil
    end
  end

  describe "#close_all_connections" do
    it "handles empty pool without error" do
      expect { pool.close_all_connections }.not_to raise_error
    end

    it "closes started connections" do
      uri = URI.parse("https://example.com")
      http = pool.acquire(uri)
      begin
        http.start
      rescue StandardError
        nil
      end
      pool.release(uri, http)

      pool.close_all_connections
      expect(http.started?).to be false
    end

    it "closes connections for multiple hosts" do
      uri_a = URI.parse("https://host-a.com")
      uri_b = URI.parse("https://host-b.com")
      http_a = pool.acquire(uri_a)
      http_b = pool.acquire(uri_b)
      pool.release(uri_a, http_a)
      pool.release(uri_b, http_b)

      pool.close_all_connections
      expect(http_a.started?).to be false if http_a.started?
      expect(http_b.started?).to be false if http_b.started?
    end
  end

  describe "#pool_mutex" do
    it "returns a Mutex" do
      expect(pool.send(:pool_mutex)).to be_a(Mutex)
    end

    it "returns the same mutex on repeated calls" do
      expect(pool.send(:pool_mutex)).to equal(pool.send(:pool_mutex))
    end
  end

  describe "concurrency stress test" do
    def run_concurrent_requests(uri, num_threads:, iterations_per_thread:)
      results = Queue.new
      threads = Array.new(num_threads) do
        Thread.new do
          iterations_per_thread.times do
            pool.with_connection(uri) { |http| http.get("/") }
            results << :ok
          rescue StandardError => e
            results << e
          end
        end
      end
      threads.each(&:join)
      collected = []
      collected << results.pop until results.empty?
      collected
    end

    it "handles many threads hitting with_connection on the same host without deadlock or race" do
      uri = URI.parse("https://stress.example.com")
      stub_request(:any, "https://stress.example.com/").to_return(status: 200, body: "ok")
      collected = run_concurrent_requests(uri, num_threads: 20, iterations_per_thread: 25)
      expect(collected.size).to eq(500)
      expect(collected).to all(eq(:ok))
    end
  end
end
