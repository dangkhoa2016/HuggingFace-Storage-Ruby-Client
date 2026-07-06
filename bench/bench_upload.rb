# frozen_string_literal: true

$LOAD_PATH.unshift(File.expand_path("../src", __dir__))
require_relative "../src/hugging_face_storage"
require "benchmark"
require "digest/sha2"

hasher = HuggingFaceStorage::XetHasher.new
serializer = HuggingFaceStorage::XetSerializer.new(hasher)
key = HuggingFaceStorage::XetHasher::DATA_KEY

sizes = {
  "1 KB" => 1_024,
  "10 KB" => 10_240,
  "100 KB" => 102_400,
  "1 MB" => 1_048_576,
  "10 MB" => 10_485_760,
}

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
puts "Upload Pipeline Benchmark"
puts "=" * 70

# ── CDC Chunking ──

puts
puts "## CDC Chunking"
cdc_rows = []
sizes.each do |label, size|
  data = Random.bytes(size)
  time = Benchmark.measure { 10.times { hasher.cdc_chunk(data) } }
  chunks = hasher.cdc_chunk(data)
  avg_chunk = chunks.sum { |s, e| e - s }.to_f / chunks.size
  throughput_mb = (size * 10 / time.real / 1_048_576).round(1)
  cdc_rows << {
    "Size" => label,
    "Runs" => 10,
    "Time(s)" => time.real.round(4),
    "Chunks" => chunks.size,
    "Avg Chunk" => "#{avg_chunk.round(0)} B",
    "MB/s" => throughput_mb,
  }
end
format_table(cdc_rows)

# ── Sequential Blake3 ──

puts
puts "## Sequential Blake3 (blake3_keyed per chunk)"
seq_rows = []
sizes.each do |label, size|
  data = Random.bytes(size)
  chunk_ranges = hasher.cdc_chunk(data)
  chunks_data = chunk_ranges.map { |s, e| data.byteslice(s, e - s) }

  time = Benchmark.measure do
    10.times { chunks_data.each { |cd| hasher.blake3_keyed(key, cd) } }
  end
  throughput_mb = (size * 10 / time.real / 1_048_576).round(1)
  seq_rows << {
    "Size" => label,
    "Chunks" => chunks_data.size,
    "Runs" => 10,
    "Time(s)" => time.real.round(4),
    "MB/s" => throughput_mb,
  }
end
format_table(seq_rows)

# ── Batch Blake3 ──

puts
puts "## Batch Blake3 (batch_blake3_keyed, 4 threads)"
batch_rows = []
sizes.each do |label, size|
  data = Random.bytes(size)
  chunk_ranges = hasher.cdc_chunk(data)
  chunks_data = chunk_ranges.map { |s, e| data.byteslice(s, e - s) }

  time = Benchmark.measure do
    10.times { hasher.batch_blake3_keyed(key, chunks_data, num_threads: 4) }
  end
  throughput_mb = (size * 10 / time.real / 1_048_576).round(1)
  batch_rows << {
    "Size" => label,
    "Chunks" => chunks_data.size,
    "Runs" => 10,
    "Time(s)" => time.real.round(4),
    "MB/s" => throughput_mb,
  }
end
format_table(batch_rows)

# ── Full Upload Pipeline (CDC + hash + xorb + shard) ──

puts
puts "## Full Upload Pipeline (CDC + batch hash + serialize xorb + build shard)"
full_rows = []
sizes.each do |label, size|
  data = Random.bytes(size)

  time = Benchmark.measure do
    10.times do
      chunk_ranges = hasher.cdc_chunk(data)
      chunks_data = chunk_ranges.map { |s, e| data.byteslice(s, e - s) }
      chunk_lengths = chunks_data.map(&:bytesize)
      chunk_hashes = hasher.batch_blake3_keyed(key, chunks_data, num_threads: 4)
      chunks_info = chunk_hashes.zip(chunk_lengths)
      xorb_hash = hasher.compute_xorb_hash(chunks_info)
      _file_hash = hasher.compute_file_hash(xorb_hash)
      _sha256 = Digest::SHA256.digest(data)
      _range_hash = hasher.compute_verification_hash(chunk_hashes)
      xorb_serialized = serializer.serialize_xorb(chunks_data)
      representation = [{
        xorb_hash: xorb_hash,
        index_start: 0, index_end: chunk_hashes.length,
        length: chunk_lengths.sum,
        range_hash: hasher.compute_verification_hash(chunk_hashes)
      }]
      serializer.build_shard(
        file_hash: _file_hash, representation: representation,
        chunk_hashes: chunk_hashes, chunk_lengths: chunk_lengths,
        xorb_hash: xorb_hash, xorb_serialized_size: xorb_serialized.bytesize,
        sha256: _sha256
      )
    end
  end
  throughput_mb = (size * 10 / time.real / 1_048_576).round(1)
  full_rows << {
    "Size" => label,
    "Runs" => 10,
    "Time(s)" => time.real.round(4),
    "MB/s" => throughput_mb,
  }
end
format_table(full_rows)

# ── Batch Upload Pipeline (multiple files) ──

puts
puts "## Batch Upload Pipeline (multiple small files)"
batch_configs = [
  { label: "20 x 1 KB", count: 20, size: 1_024 },
  { label: "10 x 10 KB", count: 10, size: 10_240 },
  { label: "5 x 100 KB", count: 5, size: 102_400 },
]
multi_rows = []
batch_configs.each do |cfg|
  files = cfg[:count].times.map { Random.bytes(cfg[:size]) }

  time = Benchmark.measure do
    10.times do
      all_chunk_metas = []
      file_metas = []
      global_chunk_idx = 0
      pending_xorb_chunks = []

      files.each do |data|
        chunk_ranges = hasher.cdc_chunk(data)
        chunks_data = chunk_ranges.map { |s, e| data.byteslice(s, e - s) }
        chunk_lengths = chunks_data.map(&:bytesize)
        chunk_hashes = hasher.batch_blake3_keyed(key, chunks_data, num_threads: 4)

        chunks_data.each_with_index do |cd, ci|
          pending_xorb_chunks << { data: cd, hash: chunk_hashes[ci], length: chunk_lengths[ci] }
          all_chunk_metas << { hash: chunk_hashes[ci], length: chunk_lengths[ci] }
          global_chunk_idx += 1
        end

        chunks_info = chunk_hashes.zip(chunk_lengths)
        xorb_hash = hasher.compute_xorb_hash(chunks_info)
        file_hash = hasher.compute_file_hash(xorb_hash)

        file_metas << {
          file_hash: file_hash, sha256: Digest::SHA256.digest(data),
          chunk_start: global_chunk_idx - chunks_data.size,
          chunk_count: chunks_data.size, size: data.bytesize,
          remote_path: "file_#{file_metas.size}.bin"
        }
      end

      serialized = serializer.serialize_xorb(pending_xorb_chunks.map { |c| c[:data] })
      chunks_info = pending_xorb_chunks.map { |c| { hash: c[:hash], length: c[:length] } }
      xorb_hash = hasher.compute_xorb_hash(chunks_info)
      uploaded_xorbs = [{ hash: xorb_hash, chunks: chunks_info, serialized_size: serialized.bytesize }]

      file_metas.each do |fm|
        fm[:representation] = serializer.build_representation(
          fm[:chunk_start], fm[:chunk_count], all_chunk_metas, uploaded_xorbs
        )
      end
      serializer.build_multi_file_shard(file_metas, uploaded_xorbs)
    end
  end
  total_bytes = cfg[:count] * cfg[:size] * 10
  throughput_mb = (total_bytes / time.real / 1_048_576).round(1)
  multi_rows << {
    "Config" => cfg[:label],
    "Runs" => 10,
    "Time(s)" => time.real.round(4),
    "MB/s" => throughput_mb,
  }
end
format_table(multi_rows)

puts
puts "Done."
