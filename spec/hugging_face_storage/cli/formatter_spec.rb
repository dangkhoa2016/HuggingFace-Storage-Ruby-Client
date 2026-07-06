# frozen_string_literal: true

require "spec_helper"

RSpec.describe HuggingFaceStorage::CLIFormatter do
  describe ".format_table" do
    it "returns empty string for empty rows" do
      expect(described_class.format_table([], %w[Name Value])).to eq("")
    end

    it "formats rows with headers as a text table" do
      rows = [["foo", "123"], ["bar", "4567"]]
      result = described_class.format_table(rows, %w[Name Value])
      lines = result.split("\n")
      expect(lines[0]).to include("Name  Value")
      expect(lines[1]).to include("----  -----")
      expect(lines[2]).to include("foo   123")
      expect(lines[3]).to include("bar   4567")
    end

    it "aligns columns by maximum width" do
      rows = [["short", "x"], ["very_long_name", "yz"]]
      result = described_class.format_table(rows, %w[Name Val])
      lines = result.split("\n")
      expect(lines[2]).to include("short           x")
    end

    it "handles rows with nil values" do
      rows = [[nil, "b"]]
      result = described_class.format_table(rows, %w[x y])
      expect(result).to include("b")
    end
  end

  describe ".compute_column_widths" do
    it "uses header width when content is shorter" do
      widths = described_class.compute_column_widths([["a"]], ["Header"])
      expect(widths).to eq([6])
    end

    it "uses content width when content is wider" do
      widths = described_class.compute_column_widths([["long_value"]], ["H"])
      expect(widths).to eq([10])
    end
  end

  describe ".format_json" do
    it "pretty-prints JSON" do
      data = { key: "value", num: 42 }
      result = described_class.format_json(data)
      parsed = JSON.parse(result)
      expect(parsed).to eq({ "key" => "value", "num" => 42 })
    end

    it "handles empty data" do
      result = described_class.format_json([])
      expect { JSON.parse(result) }.not_to raise_error
    end
  end

  describe ".format_error" do
    it "returns red error message" do
      result = described_class.format_error("Something went wrong")
      expect(result).to include("Error: Something went wrong")
      expect(result).to include(HuggingFaceStorage::Color::RED)
      expect(result).to include(HuggingFaceStorage::Color::RESET)
    end

    it "includes yellow hint when provided" do
      result = described_class.format_error("fail", hint: "try again")
      expect(result).to include("Hint: try again")
      expect(result).to include(HuggingFaceStorage::Color::YELLOW)
    end

    it "omits hint when not provided" do
      result = described_class.format_error("fail")
      expect(result).not_to include("Hint:")
    end
  end

  describe ".parse_bucket" do
    it "parses namespace/name" do
      expect(described_class.parse_bucket("user/repo")).to eq({ namespace: "user", name: "repo" })
    end

    it "raises ArgumentError for missing slash" do
      expect { described_class.parse_bucket("invalid") }
        .to raise_error(ArgumentError, /Bucket must be in form/)
    end

    it "raises ArgumentError for empty string" do
      expect { described_class.parse_bucket("") }
        .to raise_error(ArgumentError, /Bucket must be in form/)
    end

    it "handles namespace with nested slashes" do
      expect(described_class.parse_bucket("org/team/repo")).to eq({ namespace: "org", name: "team/repo" })
    end

    it "converts argument via to_s" do
      spec = double(to_s: "ns/bucket")
      result = described_class.parse_bucket(spec)
      expect(result[:namespace]).to eq("ns")
      expect(result[:name]).to eq("bucket")
    end
  end

  describe ".read_session_token" do
    let(:token_path) { File.expand_path("~/.huggingface/token") }

    before do
      allow(File).to receive(:read).with(token_path).and_return("my_test_token\n")
    end

    it "reads and strips token from file" do
      expect(described_class.read_session_token).to eq("my_test_token")
    end

    it "returns nil when file does not exist" do
      allow(File).to receive(:read).with(token_path).and_raise(Errno::ENOENT)
      expect(described_class.read_session_token).to be_nil
    end

    it "returns nil on system call error and prints warning" do
      allow(File).to receive(:read).with(token_path).and_raise(Errno::EACCES)
      expect { described_class.read_session_token }
        .to output(/Warning: Unable to read token/).to_stderr
    end
  end

  describe ".format_output" do
    it "prints JSON when format is json" do
      data = [{ path: "a.txt", size: 100 }]
      expect { described_class.format_output(data, "json") }
        .to output(/a\.txt/).to_stdout
    end

    it "prints table when format is table with headers" do
      data = [["a.txt", 100]]
      expect { described_class.format_output(data, "table", headers: %w[path size]) }
        .to output(/a\.txt.*100/m).to_stdout
    end

    it "prints each row when no headers" do
      data = ["row1", "row2"]
      expect { described_class.format_output(data, "table") }
        .to output(/row1\nrow2/).to_stdout
    end
  end

  describe ".build_client" do
    it "creates a client from bucket spec with explicit token" do
      client = described_class.build_client("user/repo", token: "hf_test")
      expect(client).to be_a(HuggingFaceStorage::Client)
      expect(client.bucket_id).to eq("user/repo")
    end

    it "falls back to HF_TOKEN env var when no token given" do
      orig = ENV["HF_TOKEN"]
      ENV["HF_TOKEN"] = "env_token"
      client = described_class.build_client("user/repo")
      expect(client).to be_a(HuggingFaceStorage::Client)
      expect(client.bucket_id).to eq("user/repo")
    ensure
      ENV["HF_TOKEN"] = orig
    end

    it "falls back to session token file when ENV and arg are nil" do
      orig = ENV["HF_TOKEN"]
      ENV["HF_TOKEN"] = nil
      allow(described_class).to receive(:read_session_token).and_return("file_token")
      client = described_class.build_client("test-ns/test-bucket")
      expect(client).to be_a(HuggingFaceStorage::Client)
    ensure
      ENV["HF_TOKEN"] = orig
    end
  end
end
