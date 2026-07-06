# frozen_string_literal: true

require "spec_helper"

# Multiple top-level describe blocks for different aspect groups.
# rubocop:disable RSpec/RepeatedExampleGroupDescription
RSpec.describe HuggingFaceStorage::HFLogger do
  describe "#initialize" do
    it "creates logger with default settings" do
      logger = described_class.new
      expect(logger.level).to eq(:info)
    end

    it "accepts :debug level" do
      logger = described_class.new(level: :debug)
      expect(logger.level).to eq(:debug)
    end

    it "accepts integer level" do
      logger = described_class.new(level: ::Logger::WARN)
      expect(logger.level).to eq(:warn)
    end

    it "accepts Integer level 0..4 at runtime" do
      logger = described_class.new(level: 0)
      expect(logger.level).to eq(:debug)
    end

    it "accepts StringIO output" do
      io = StringIO.new
      logger = described_class.new(output: io)
      logger.info("hello")
      expect(io.string).to include("hello")
    end

    it "writes to file when output is a path" do
      Dir.mktmpdir do |dir|
        path = File.join(dir, "test.log")
        orig_stdout = $stdout
        $stdout = StringIO.new
        begin
          logger = described_class.new(output: path)
          logger.info("file log test")
          logger.close
          expect(File.read(path)).to include("file log test")
        ensure
          $stdout = orig_stdout
        end
      end
    end
  end

  describe "log levels" do
    let(:output) { StringIO.new }
    let(:logger) { described_class.new(level: :debug, output: output) }

    %i[debug info warn error fatal].each do |level|
      it "logs at #{level} level" do
        logger.public_send(level, "test #{level}")
        expect(output.string).to include("test #{level}")
      end
    end

    it "filters messages below current level" do
      logger.level = :warn
      logger.debug("should not appear")
      logger.info("should not appear either")
      expect(output.string).not_to include("should not appear")
    end
  end

  describe "log formats" do
    it "uses default format with timestamp and level" do
      output = StringIO.new
      logger = described_class.new(level: :info, output: output, format: :default)
      logger.info("default format test")
      clean_output = output.string.gsub(/\e\[[0-9;]*m/, '')
      expect(clean_output).to match(/\[\d{2}:\d{2}:\d{2}\.\d{3}\] INFO\s+default format test/)
    end

    it "uses JSON format" do
      output = StringIO.new
      logger = described_class.new(level: :info, output: output, format: :json)
      logger.info("json test")
      parsed = JSON.parse(output.string.strip)
      expect(parsed["level"]).to eq("INFO")
      expect(parsed["message"]).to eq("json test")
      expect(parsed["timestamp"]).to be_a(String)
    end

    it "uses short format" do
      output = StringIO.new
      logger = described_class.new(level: :info, output: output, format: :short)
      logger.info("short test")
      expect(output.string).to match(/I \d{2}:\d{2}:\d{2}\.\d{3} short test/)
    end

    it "uses plain format (no color, full timestamp)" do
      output = StringIO.new
      logger = described_class.new(level: :info, output: output, format: :plain)
      logger.info("plain test")
      expect(output.string).to match(/\[\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\.\d{3}\] \[INFO\] plain test/)
      expect(output.string).not_to include("\e[")
    end

    it "uses plain format with color when color is enabled" do
      output = StringIO.new
      logger = described_class.new(level: :info, output: output, format: :plain, color: true)
      logger.info("plain color test")
      expect(output.string).to include("\e[32m")
      expect(output.string).to include("plain color test")
    end

    it "accepts custom Proc format" do
      output = StringIO.new
      custom = ->(time, level, msg, color) { "CUSTOM: #{msg}" }
      logger = described_class.new(level: :info, output: output, format: custom)
      logger.info("proc test")
      expect(output.string).to include("CUSTOM: proc test")
    end
  end

  describe "#format and #format=" do
    it "returns current format symbol" do
      logger = described_class.new(level: :info, format: :json)
      expect(logger.format).to eq(:json)
    end

    it "changes format at runtime" do
      output = StringIO.new
      logger = described_class.new(level: :info, output: output, format: :default)
      logger.format = :json
      logger.info("after change")
      parsed = JSON.parse(output.string.strip)
      expect(parsed["message"]).to eq("after change")
    end

    it "returns the Proc object for custom format" do
      custom = ->(t, l, m, c) { "x" }
      logger = described_class.new(level: :info, format: custom)
      expect(logger.format).to be(custom)
    end
  end

  describe "#level=" do
    it "changes log level at runtime" do
      logger = described_class.new(level: :info)
      logger.level = :debug
      expect(logger.level).to eq(:debug)
    end

    it "accepts Integer level (0..4) at runtime" do
      logger = described_class.new(level: :info)
      logger.level = 0
      expect(logger.level).to eq(:debug)
    end
  end

  describe "block-based logging" do
    it "evaluates block only when level is met" do
      output = StringIO.new
      logger = described_class.new(level: :warn, output: output)
      called = false
      logger.debug { called = true; "should not log" }
      expect(called).to be false
      expect(output.string).to be_empty
    end

    it "evaluates block when level is appropriate" do
      output = StringIO.new
      logger = described_class.new(level: :debug, output: output)
      logger.debug { "block message" }
      expect(output.string).to include("block message")
    end
  end

  describe "log color" do
    it "does not include ANSI codes when color is false" do
      output = StringIO.new
      logger = described_class.new(level: :info, output: output, color: false)
      logger.info("no color")
      expect(output.string).not_to include("\e[")
    end

    it "includes ANSI codes when color is true" do
      output = StringIO.new
      logger = described_class.new(level: :info, output: output, color: true)
      logger.info("with color")
      expect(output.string).to include("\e[")
    end

    it "auto-detects TTY and disables color for non-TTY output" do
      output = StringIO.new
      logger = described_class.new(level: :info, output: output, color: :auto)
      logger.info("auto mode")
      expect(output.string).not_to include("\e[")
    end

    it "disables color for unknown color option" do
      output = StringIO.new
      logger = described_class.new(level: :info, output: output, color: :bogus)
      logger.info("unknown color opt")
      expect(output.string).not_to include("\e[")
    end
  end

  describe "resolve edge cases" do
    it "defaults to INFO for unknown level symbol" do
      logger = described_class.new(level: :unknown_level)
      expect(logger.level).to eq(:info)
    end

    it "defaults to INFO for unknown level type" do
      logger = described_class.new(level: { bad: true })
      expect(logger.level).to eq(:info)
    end

    it "accepts $stderr as output" do
      logger = described_class.new(level: :info, output: $stderr, color: false)
      expect(logger.level).to eq(:info)
    end

    it "accepts :stderr as output" do
      logger = described_class.new(level: :info, output: :stderr, color: false)
      expect(logger.level).to eq(:info)
    end

    it "accepts custom writable object as output" do
      custom_io = Object.new
      def custom_io.write(data); end
      def custom_io.close; end
      logger = described_class.new(level: :info, output: custom_io, color: false)
      logger.info("custom output")
    end

    it "falls back to $stdout for objects that do not respond to write" do
      logger = described_class.new(level: :info, output: Object.new, color: false)
      expect(logger.level).to eq(:info)
    end

    it "defaults to :default format for unknown symbol" do
      output = StringIO.new
      logger = described_class.new(level: :info, output: output, format: :bogus)
      logger.info("unknown format")
      expect(output.string).to include("unknown format")
    end

    it "defaults to :default format for non-symbol non-proc" do
      output = StringIO.new
      logger = described_class.new(level: :info, output: output, format: 42)
      logger.info("numeric format")
      expect(output.string).to include("numeric format")
    end
  end

  describe ".colorize_message" do
    it "dims debug messages" do
      dimmed = described_class.colorize_message("DEBUG", "test debug")
      expect(dimmed).to eq("\e[2mtest debug\e[0m")
    end

    it "highlights file sizes" do
      result = described_class.colorize_message("INFO", "Uploaded 1.5 MB")
      expect(result).to include("1.5 MB")
      expect(result).to include("\e[93m")
    end

    it "highlights HTTP status codes" do
      result = described_class.colorize_message("INFO", "HTTP 200 OK")
      expect(result).to include("\e[92m")
    end

    it "highlights HTTP error codes in red" do
      result = described_class.colorize_message("INFO", "HTTP 500")
      expect(result).to include("\e[91m")
    end

    it "highlights elapsed time" do
      result = described_class.colorize_message("INFO", "Completed in 342ms")
      expect(result).to include("\e[95m")
    end

    it "highlights file counts" do
      result = described_class.colorize_message("INFO", "Deleted 7 file(s)")
      expect(result).to include("\e[97m")
    end

    it "highlights progress markers" do
      result = described_class.colorize_message("INFO", "[3/10] Processing")
      expect(result).to include("\e[1m\e[96m")
    end

    it "highlights path-like tokens" do
      result = described_class.colorize_message("INFO", "/api/buckets/user/bucket/tree")
      expect(result).to include("\e[36m")
    end

    it "highlights repo identifiers" do
      result = described_class.colorize_message("INFO", "model:google/gemma-4-12B-it")
      expect(result).to include("\e[94m")
    end

    it "highlights completion keywords" do
      result = described_class.colorize_message("INFO", "Upload complete")
      expect(result).to include("\e[92m")
    end

    it "caches and reuses previously computed results" do
      msg = "Uploaded 1.5 MB and 342ms elapsed"
      first = described_class.colorize_message("INFO", msg)
      second = described_class.colorize_message("INFO", msg)
      expect(first).to eq(second)
    end

    it "is thread-safe when called concurrently from multiple threads" do
      messages = 50.times.map { |i| "Upload complete: #{i} file(s) 1.5 MB in 342ms /path/to/#{i}" }
      results = Array.new(messages.size)
      errors = []
      threads = 8.times.map do |t|
        Thread.new do
          messages.each_with_index { |msg, i|
            results[((t * messages.size) + i) % results.size] = described_class.colorize_message("INFO", msg)
          }
        rescue StandardError => e
          errors << e
        end
      end
      threads.each(&:join)
      expect(errors).to be_empty
      expect(results.compact).to all(include("\e["))
    end
  end
end

RSpec.describe HuggingFaceStorage::Color do
  describe ".strip" do
    it "removes ANSI escape codes from string" do
      colored = "\e[31mred text\e[0m"
      expect(described_class.strip(colored)).to eq("red text")
    end
  end
end

RSpec.describe HuggingFaceStorage::StripIO do
  it "delegates respond_to_missing? to the wrapped IO" do
    io = StringIO.new
    wrapper = described_class.new(io)

    expect(wrapper).to respond_to(:string)
    expect(wrapper).not_to respond_to(:definitely_missing)
  end
end

RSpec.describe HuggingFaceStorage::TeeIO do
  it "delegates respond_to_missing? to the first IO" do
    io = StringIO.new
    wrapper = described_class.new(io)

    expect(wrapper).to respond_to(:string)
    expect(wrapper).not_to respond_to(:definitely_missing)
  end
end

RSpec.describe HuggingFaceStorage::HFLogger do
  describe "#close" do
    it "closes file output and persists logged data" do
      Dir.mktmpdir do |dir|
        path = File.join(dir, "test.log")
        orig_stdout = $stdout
        $stdout = StringIO.new
        begin
          logger = described_class.new(output: path)
          logger.info("pre-close")
          expect { logger.close }.not_to raise_error
          expect(File.read(path)).to include("pre-close")
        ensure
          $stdout = orig_stdout
        end
      end
    end

    it "can be safely called when wrapping stdout" do
      logger = described_class.new(output: $stdout)
      expect { logger.close }.not_to raise_error
    end

    it "can be safely called when wrapping stderr" do
      logger = described_class.new(output: :stderr)
      expect { logger.close }.not_to raise_error
    end

    it "is idempotent — second call is a no-op" do
      io = StringIO.new
      logger = described_class.new(level: :info, output: io)
      logger.info("data")
      2.times { logger.close }
      expect(io).to be_closed
    end

    it "does not raise when closed before any write" do
      io = StringIO.new
      logger = described_class.new(output: io)
      expect { logger.close }.not_to raise_error
    end
  end
end

RSpec.describe HuggingFaceStorage::NullLogger do
  subject(:logger) { described_class.new }

  %i[debug info warn error fatal].each do |level|
    it "responds to #{level} without error" do
      expect { logger.public_send(level, "message") }.not_to raise_error
    end

    it "accepts block form for #{level} without error" do
      expect { logger.public_send(level) { "message" } }.not_to raise_error
    end
  end

  it "returns :info for level" do
    expect(logger.level).to eq(:info)
  end

  it "accepts level= without error" do
    expect { logger.level = :debug }.not_to raise_error
  end

  it "returns :default for format" do
    expect(logger.format).to eq(:default)
  end

  it "accepts format= without error" do
    expect { logger.format = :json }.not_to raise_error
  end

  it "accepts close without error" do
    expect { logger.close }.not_to raise_error
  end
end
# rubocop:enable RSpec/RepeatedExampleGroupDescription
