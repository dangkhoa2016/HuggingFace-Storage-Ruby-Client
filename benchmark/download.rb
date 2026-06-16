# frozen_string_literal: true

require_relative "helper"
require "tempfile"

if __FILE__ == $PROGRAM_NAME
  # Already runs standalone via rake task
  # This guard is for verification
end

include BenchmarkHelper

hasher = HuggingFaceStorage::XetHasher.new
serializer = HuggingFaceStorage::XetSerializer.new(hasher)

print_header("Download Pipeline Benchmark")

CHUNK_HEADER_SIZE = HuggingFaceStorage::XetHasher::CHUNK_HEADER_SIZE

extract_chunks = lambda do |xorb_data|
  chunks = []
  offset = 0
  while offset < xorb_data.bytesize
    _flags = xorb_data.getbyte(offset)
    csize = xorb_data.getbyte(offset + 1) |
            (xorb_data.getbyte(offset + 2) << 8) |
            (xorb_data.getbyte(offset + 3) << 16)
    offset += CHUNK_HEADER_SIZE
    chunks << xorb_data.byteslice(offset, csize)
    offset += csize
  end
  chunks
end

# ── Xorb Chunk Extraction ──

safe_bench("Xorb Chunk Extraction") do
  xorb_configs = {
    "10 chunks (~640 KB)" => 10,
    "50 chunks (~3.2 MB)" => 50,
    "200 chunks (~12.8 MB)" => 200,
  }

  stats_rows = []
  xorb_configs.each do |label, num_chunks|
    chunks_data = num_chunks.times.map { Random.bytes(HuggingFaceStorage::XetHasher::TARGET_CHUNK) }
    xorb_data = serializer.serialize_xorb(chunks_data)

    warmup { extract_chunks.call(xorb_data) }
    stats = statistical_run(data_size: xorb_data.bytesize) { extract_chunks.call(xorb_data) }
    stats_rows << {
      "Config" => label,
      "Xorb Size" => "#{(xorb_data.bytesize / 1_048_576.0).round(2)} MB",
      "Iters" => stats[:iterations],
      "Min(s)" => stats[:min].round(4),
      "Max(s)" => stats[:max].round(4),
      "Avg(s)" => stats[:avg].round(4),
      "Med(s)" => stats[:median].round(4),
      "MB/s" => stats[:throughput_mbps],
    }
  end
  print_stats_table(stats_rows)
end

# ── File Reassembly ──

safe_bench("File Reassembly (write chunks -> temp file)") do
  reassembly_configs = {
    "1 MB (16 chunks)" => { chunks: 16, chunk_size: 65_536 },
    "10 MB (160 chunks)" => { chunks: 160, chunk_size: 65_536 },
    "100 MB (1600 chunks)" => { chunks: 1600, chunk_size: 65_536 },
  }

  stats_rows = []
  reassembly_configs.each do |label, cfg|
    chunks_data = cfg[:chunks].times.map { Random.bytes(cfg[:chunk_size]) }
    total_bytes = cfg[:chunks] * cfg[:chunk_size]

    warmup do
      Tempfile.create(["bench_reassembly", ".bin"]) do |f|
        f.binmode
        chunks_data.each { |cd| f.write(cd) }
      end
    end

    stats = statistical_run(data_size: total_bytes) do
      Tempfile.create(["bench_reassembly", ".bin"]) do |f|
        f.binmode
        chunks_data.each { |cd| f.write(cd) }
      end
    end

    stats_rows << {
      "Config" => label,
      "Iters" => stats[:iterations],
      "Min(s)" => stats[:min].round(4),
      "Max(s)" => stats[:max].round(4),
      "Avg(s)" => stats[:avg].round(4),
      "Med(s)" => stats[:median].round(4),
      "MB/s" => stats[:throughput_mbps],
    }
  end
  print_stats_table(stats_rows)
end

# ── Stream Write ──

safe_bench("Stream Write (simulate chunked download to file)") do
  stream_configs = {
    "1 MB (8 KB chunks)" => { total: 1_048_576, chunk: 8_192 },
    "10 MB (64 KB chunks)" => { total: 10_485_760, chunk: 65_536 },
    "10 MB (256 KB chunks)" => { total: 10_485_760, chunk: 262_144 },
  }

  stats_rows = []
  stream_configs.each do |label, cfg|
    num_chunks = cfg[:total] / cfg[:chunk]
    chunks = num_chunks.times.map { Random.bytes(cfg[:chunk]) }

    warmup do
      Tempfile.create(["bench_stream", ".bin"]) do |f|
        f.binmode
        chunks.each { |c| f.write(c) }
      end
    end

    stats = statistical_run(data_size: cfg[:total]) do
      Tempfile.create(["bench_stream", ".bin"]) do |f|
        f.binmode
        chunks.each { |c| f.write(c) }
      end
    end

    stats_rows << {
      "Config" => label,
      "Iters" => stats[:iterations],
      "Min(s)" => stats[:min].round(4),
      "Max(s)" => stats[:max].round(4),
      "Avg(s)" => stats[:avg].round(4),
      "Med(s)" => stats[:median].round(4),
      "MB/s" => stats[:throughput_mbps],
    }
  end
  print_stats_table(stats_rows)
end

# ── SHA256 Verification ──

safe_bench("SHA256 Verification") do
  sha_sizes = {
    "1 MB" => 1_048_576,
    "10 MB" => 10_485_760,
    "100 MB" => 104_857_600,
  }

  stats_rows = []
  sha_sizes.each do |label, size|
    data = Random.bytes(size)

    warmup { Digest::SHA256.digest(data) }
    stats = statistical_run(data_size: size) { Digest::SHA256.digest(data) }
    stats_rows << {
      "Size" => label,
      "Iters" => stats[:iterations],
      "Min(s)" => stats[:min].round(4),
      "Max(s)" => stats[:max].round(4),
      "Avg(s)" => stats[:avg].round(4),
      "Med(s)" => stats[:median].round(4),
      "MB/s" => stats[:throughput_mbps],
    }
  end
  print_stats_table(stats_rows)
end

puts
puts "Done."
