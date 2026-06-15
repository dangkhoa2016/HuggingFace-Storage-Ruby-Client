# frozen_string_literal: true

$LOAD_PATH.unshift(File.expand_path("../src", __dir__))
require_relative "../src/hugging_face_storage"
require "benchmark"

hasher = HuggingFaceStorage::XetHasher.new
key = HuggingFaceStorage::XetHasher::DATA_KEY

sizes = {
  "1 KB" => 1024,
  "10 KB" => 10_240,
  "100 KB" => 102_400,
}

puts "=" * 60
puts "CDC Chunking Benchmark"
puts "=" * 60

sizes.each do |label, size|
  data = Random.bytes(size)

  time = Benchmark.measure do
    10.times { hasher.cdc_chunk(data) }
  end

  chunks = hasher.cdc_chunk(data)
  avg_chunk = chunks.sum { |s, e| e - s }.to_f / chunks.size

  puts "#{label.ljust(10)} | 10 runs: #{time.real.round(3)}s | #{chunks.size} chunks | avg: #{avg_chunk.round(0)} bytes"
end

puts
puts "=" * 60
puts "Blake3 Keyed Hash Benchmark"
puts "=" * 60

sizes.each do |label, size|
  data = Random.bytes(size)

  time = Benchmark.measure do
    100.times { hasher.blake3_keyed(key, data) }
  end

  puts "#{label.ljust(10)} | 100 runs: #{time.real.round(3)}s | #{(100 / time.real).round(0)} hashes/sec"
end

puts
puts "=" * 60
puts "Xorb Hash Tree Benchmark"
puts "=" * 60

[10, 50, 200].each do |num_chunks|
  chunk_hashes = num_chunks.times.map { Random.bytes(32) }
  chunk_lengths = num_chunks.times.map { rand(8192..131_072) }
  infos = chunk_hashes.zip(chunk_lengths)

  time = Benchmark.measure do
    10.times { hasher.compute_xorb_hash(infos) }
  end

  puts "#{num_chunks} chunks | 10 runs: #{time.real.round(3)}s"
end

puts
puts "=" * 60
puts "Utils.human_size Benchmark"
puts "=" * 60

time = Benchmark.measure do
  10_000.times { HuggingFaceStorage::Utils.human_size(rand(0..1_099_511_627_776)) }
end

puts "10,000 runs: #{time.real.round(3)}s"

puts
puts "Done."
