# frozen_string_literal: true

$LOAD_PATH.unshift(File.expand_path("../src", __dir__))
require_relative "../src/hugging_face_storage"
require "benchmark"
require "tempfile"
require "digest/sha2"

hasher = HuggingFaceStorage::XetHasher.new
serializer = HuggingFaceStorage::XetSerializer.new(hasher)

def format_table(rows)
  return if rows.empty?

  headers = rows.first.keys.map(&:to_s)
  widths = headers.map(&:length)
  rows.each do |row|
    row.values.each_with_index do |v, i|
      widths[i] = [widths[i], v.to_s.length].max
    end
  end
  sep = widths.map { |w| "-" * (w + 2) }.join("+")
  sep = "+#{sep}+"
  header_line = headers.each_with_index.map { |h, i| " #{h.ljust(widths[i])} " }.join("|")
  puts sep
  puts "|#{header_line}|"
  puts sep
  rows.each do |row|
    line = row.values.each_with_index.map { |v, i| " #{v.to_s.rjust(widths[i])} " }.join("|")
    puts "|#{line}|"
  end
  puts sep
end

puts "=" * 70
puts "Download Pipeline Benchmark"
puts "=" * 70

# ── Chunk extraction from serialized xorb ──

puts
puts "## Xorb Chunk Extraction"
puts "   (deserialize xorb binary → extract chunks)"

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

xorb_sizes = {
  "10 chunks (~640 KB)" => 10,
  "50 chunks (~3.2 MB)" => 50,
  "200 chunks (~12.8 MB)" => 200,
}

extract_rows = []
xorb_sizes.each do |label, num_chunks|
  chunks_data = num_chunks.times.map { Random.bytes(HuggingFaceStorage::XetHasher::TARGET_CHUNK) }
  xorb_data = serializer.serialize_xorb(chunks_data)

  time = Benchmark.measure { 10.times { extract_chunks.call(xorb_data) } }
  throughput_mb = (xorb_data.bytesize * 10 / time.real / 1_048_576).round(1)
  extract_rows << {
    "Config" => label,
    "Xorb Size" => "#{(xorb_data.bytesize / 1_048_576.0).round(2)} MB",
    "Runs" => 10,
    "Time(s)" => time.real.round(4),
    "MB/s" => throughput_mb,
  }
end
format_table(extract_rows)

# ── File reassembly from chunks ──

puts
puts "## File Reassembly (write chunks → temp file)"

reassembly_sizes = {
  "1 MB (16 chunks)" => { chunks: 16, chunk_size: 65_536 },
  "10 MB (160 chunks)" => { chunks: 160, chunk_size: 65_536 },
  "100 MB (1600 chunks)" => { chunks: 1600, chunk_size: 65_536 },
}

reassembly_rows = []
reassembly_sizes.each do |label, cfg|
  chunks_data = cfg[:chunks].times.map { Random.bytes(cfg[:chunk_size]) }

  time = Benchmark.measure do
    5.times do
      Tempfile.create(["bench_reassembly", ".bin"]) do |f|
        f.binmode
        chunks_data.each { |cd| f.write(cd) }
      end
    end
  end
  total_bytes = cfg[:chunks] * cfg[:chunk_size] * 5
  throughput_mb = (total_bytes / time.real / 1_048_576).round(1)
  reassembly_rows << {
    "Config" => label,
    "Runs" => 5,
    "Time(s)" => time.real.round(4),
    "MB/s" => throughput_mb,
  }
end
format_table(reassembly_rows)

# ── Stream write (simulate chunked download) ──

puts
puts "## Stream Write (simulate chunked download to file)"

stream_configs = {
  "1 MB (8 KB chunks)" => { total: 1_048_576, chunk: 8_192 },
  "10 MB (64 KB chunks)" => { total: 10_485_760, chunk: 65_536 },
  "10 MB (256 KB chunks)" => { total: 10_485_760, chunk: 262_144 },
}

stream_rows = []
stream_configs.each do |label, cfg|
  num_chunks = cfg[:total] / cfg[:chunk]
  chunks = num_chunks.times.map { Random.bytes(cfg[:chunk]) }

  time = Benchmark.measure do
    5.times do
      Tempfile.create(["bench_stream", ".bin"]) do |f|
        f.binmode
        chunks.each { |c| f.write(c) }
      end
    end
  end
  total_bytes = cfg[:total] * 5
  throughput_mb = (total_bytes / time.real / 1_048_576).round(1)
  stream_rows << {
    "Config" => label,
    "Runs" => 5,
    "Time(s)" => time.real.round(4),
    "MB/s" => throughput_mb,
  }
end
format_table(stream_rows)

# ── SHA256 verification (done during download) ──

puts
puts "## SHA256 Verification"
sha_sizes = {
  "1 MB" => 1_048_576,
  "10 MB" => 10_485_760,
  "100 MB" => 104_857_600,
}

sha_rows = []
sha_sizes.each do |label, size|
  data = Random.bytes(size)

  time = Benchmark.measure { 5.times { Digest::SHA256.digest(data) } }
  throughput_mb = (size * 5 / time.real / 1_048_576).round(1)
  sha_rows << {
    "Size" => label,
    "Runs" => 5,
    "Time(s)" => time.real.round(4),
    "MB/s" => throughput_mb,
  }
end
format_table(sha_rows)

puts
puts "Done."
