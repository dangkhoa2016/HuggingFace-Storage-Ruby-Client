# frozen_string_literal: true

require_relative "helper"

include BenchmarkHelper

# Mock upload benchmark: measures full pipeline with simulated network I/O.
# Uses real hasher + serializer + pipeline, only network calls are mocked.

hasher = HuggingFaceStorage::XetHasher.new
serializer = HuggingFaceStorage::XetSerializer.new(hasher)

print_header("Full Upload Pipeline Benchmark (mocked network)")

# Simulated network latency (ms)
NETWORK_LATENCY = 5.0

# ── Single File Upload Pipeline ──

safe_bench("Single File Upload: OLD vs NEW Pipeline") do
  comp_rows = []
  SIZES.each do |label, size|
    data = Random.bytes(size)
    n = 20
    key = HuggingFaceStorage::XetHasher::DATA_KEY

    # Warmup: OLD path
    3.times do
      chunk_ranges = hasher.cdc_chunk(data)
      chunk_data = chunk_ranges.map { |s, e| data.byteslice(s, e - s) }
      chunk_lengths = chunk_data.map(&:bytesize)
      chunk_hashes = hasher.batch_blake3_keyed(key, chunk_data, num_threads: 4)
      chunks_info = chunk_hashes.zip(chunk_lengths)
      xorb_hash = hasher.compute_xorb_hash(chunks_info)
      file_hash = hasher.compute_file_hash(xorb_hash)
      sha256 = Digest::SHA256.digest(data)
      serialized = serializer.serialize_xorb(chunk_data)
      rh = hasher.compute_verification_hash(chunk_hashes)
      rep = [{ xorb_hash: xorb_hash, index_start: 0, index_end: chunk_hashes.length,
               length: chunk_lengths.sum, range_hash: rh }]
      serializer.build_shard(file_hash: file_hash, representation: rep, chunk_hashes: chunk_hashes,
                             chunk_lengths: chunk_lengths, xorb_hash: xorb_hash,
                             xorb_serialized_size: serialized.bytesize, sha256: sha256)
      sleep(NETWORK_LATENCY / 1000)  # Simulate upload_xorb
      sleep(NETWORK_LATENCY / 1000)  # Simulate upload_shard
    end

    # OLD path
    t_old = Benchmark.measure {
      n.times do
        chunk_ranges = hasher.cdc_chunk(data)
        chunk_data = chunk_ranges.map { |s, e| data.byteslice(s, e - s) }
        chunk_lengths = chunk_data.map(&:bytesize)
        chunk_hashes = hasher.batch_blake3_keyed(key, chunk_data, num_threads: 4)
        chunks_info = chunk_hashes.zip(chunk_lengths)
        xorb_hash = hasher.compute_xorb_hash(chunks_info)
        file_hash = hasher.compute_file_hash(xorb_hash)
        sha256 = Digest::SHA256.digest(data)
        serialized = serializer.serialize_xorb(chunk_data)
        rh = hasher.compute_verification_hash(chunk_hashes)
        rep = [{ xorb_hash: xorb_hash, index_start: 0, index_end: chunk_hashes.length,
                 length: chunk_lengths.sum, range_hash: rh }]
        serializer.build_shard(file_hash: file_hash, representation: rep, chunk_hashes: chunk_hashes,
                               chunk_lengths: chunk_lengths, xorb_hash: xorb_hash,
                               xorb_serialized_size: serialized.bytesize, sha256: sha256)
        sleep(NETWORK_LATENCY / 1000)  # Simulate upload_xorb
        sleep(NETWORK_LATENCY / 1000)  # Simulate upload_shard
      end
    }

    # Warmup: NEW path
    3.times do
      chunk_ranges, hashes_concat = hasher.cdc_and_hash_native(data)
      chunk_hashes = hashes_concat.unpack("a32" * (hashes_concat.bytesize / 32))
      chunk_lengths = chunk_ranges.map { |s, e| e - s }
      xorb_hash = hasher.compute_xorb_hash(chunk_hashes, chunk_lengths)
      file_hash = hasher.compute_file_hash(xorb_hash)
      sha256 = Digest::SHA256.digest(data)
      serialized = serializer.serialize_xorb_from_ranges(data, chunk_ranges)
      rh = hasher.compute_verification_hash(chunk_hashes)
      rep = [{ xorb_hash: xorb_hash, index_start: 0, index_end: chunk_hashes.length,
               length: chunk_lengths.sum, range_hash: rh }]
      serializer.build_shard(file_hash: file_hash, representation: rep, chunk_hashes: chunk_hashes,
                             chunk_lengths: chunk_lengths, xorb_hash: xorb_hash,
                             xorb_serialized_size: serialized.bytesize, sha256: sha256)
      sleep(NETWORK_LATENCY / 1000)
      sleep(NETWORK_LATENCY / 1000)
    end

    # NEW path
    t_new = Benchmark.measure {
      n.times do
        chunk_ranges, hashes_concat = hasher.cdc_and_hash_native(data)
        chunk_hashes = hashes_concat.unpack("a32" * (hashes_concat.bytesize / 32))
        chunk_lengths = chunk_ranges.map { |s, e| e - s }
        xorb_hash = hasher.compute_xorb_hash(chunk_hashes, chunk_lengths)
        file_hash = hasher.compute_file_hash(xorb_hash)
        sha256 = Digest::SHA256.digest(data)
        serialized = serializer.serialize_xorb_from_ranges(data, chunk_ranges)
        rh = hasher.compute_verification_hash(chunk_hashes)
        rep = [{ xorb_hash: xorb_hash, index_start: 0, index_end: chunk_hashes.length,
                 length: chunk_lengths.sum, range_hash: rh }]
        serializer.build_shard(file_hash: file_hash, representation: rep, chunk_hashes: chunk_hashes,
                               chunk_lengths: chunk_lengths, xorb_hash: xorb_hash,
                               xorb_serialized_size: serialized.bytesize, sha256: sha256)
        sleep(NETWORK_LATENCY / 1000)
        sleep(NETWORK_LATENCY / 1000)
      end
    }

    old_total = t_old.real / n * 1000
    new_total = t_new.real / n * 1000
    old_compute = old_total - NETWORK_LATENCY * 2  # Subtract 2 network calls
    new_compute = new_total - NETWORK_LATENCY * 2
    old_pct = (old_compute / old_total * 100).round(1)
    new_pct = (new_compute / new_total * 100).round(1)
    compute_imp = ((old_compute - new_compute) / old_compute * 100).round(1)
    total_imp = ((old_total - new_total) / old_total * 100).round(1)

    comp_rows << {
      "Size" => label,
      "OLD Total(ms)" => old_total.round(1),
      "OLD Compute(ms)" => old_compute.round(1),
      "OLD Network%" => "#{old_pct}%",
      "NEW Total(ms)" => new_total.round(1),
      "NEW Compute(ms)" => new_compute.round(1),
      "NEW Network%" => "#{new_pct}%",
      "Compute Δ" => "#{compute_imp > 0 ? '+' : ''}#{compute_imp}%",
      "Total Δ" => "#{total_imp > 0 ? '+' : ''}#{total_imp}%",
    }
  end
  print_stats_table(comp_rows)
end

# ── full_pipeline_native: CDC+Blake3+Serialize in 1 C call ──

safe_bench("full_pipeline_native: CDC+Blake3+Serialize in 1 C call") do
  comp_rows = []
  SIZES.each do |label, size|
    data = Random.bytes(size)
    n = 20
    key = HuggingFaceStorage::XetHasher::DATA_KEY

    # Warmup: separate calls
    3.times do
      chunk_ranges = hasher.cdc_chunk(data)
      chunk_hashes = hasher.batch_blake3_keyed_from_ranges(key, data, chunk_ranges, num_threads: 4)
      serialized = serializer.serialize_xorb_from_ranges(data, chunk_ranges)
    end

    # Separate calls path
    t_sep = Benchmark.measure {
      n.times do
        chunk_ranges = hasher.cdc_chunk(data)
        chunk_hashes = hasher.batch_blake3_keyed_from_ranges(key, data, chunk_ranges, num_threads: 4)
        serialized = serializer.serialize_xorb_from_ranges(data, chunk_ranges)
      end
    }

    # Warmup: full_pipeline_native
    3.times do
      hasher.full_pipeline_native(data)
    end

    # full_pipeline_native path
    t_fp = Benchmark.measure {
      n.times do
        hashes_concat, chunk_ranges, xorb_data = hasher.full_pipeline_native(data)
      end
    }

    sep_ms = t_sep.real / n * 1000
    fp_ms = t_fp.real / n * 1000
    sep_mbps = (size.to_f / t_sep.real * n / 1_048_576).round(1)
    fp_mbps = (size.to_f / t_fp.real * n / 1_048_576).round(1)
    imp = ((sep_ms - fp_ms) / sep_ms * 100).round(1)

    comp_rows << {
      "Size" => label,
      "Separate(ms)" => sep_ms.round(1),
      "Separate MB/s" => sep_mbps,
      "full_pipeline(ms)" => fp_ms.round(1),
      "full_pipeline MB/s" => fp_mbps,
      "Δ" => "#{imp.positive? ? '+' : ''}#{imp}%",
    }
  end
  print_stats_table(comp_rows)
end

# ── Parallel SHA-256: sync vs persistent worker ──

safe_bench("SHA-256: sync vs persistent worker thread") do
  comp_rows = []
  SIZES.each do |label, size|
    data = Random.bytes(size)
    n = 30

    # Warmup
    3.times { Digest::SHA256.digest(data) }

    # Sync SHA-256
    t_sync = Benchmark.measure { n.times { Digest::SHA256.digest(data) } }

    # Persistent worker SHA-256 (simulated)
    sha256_mutex = Mutex.new
    sha256_cv = ConditionVariable.new
    sha256_request = nil
    sha256_result = nil

    worker = Thread.new do
      loop do
        data_local = nil
        sha256_mutex.synchronize do
          loop do
            break if sha256_request

            sha256_cv.wait(sha256_mutex)
          end
          data_local = sha256_request
          sha256_request = nil
        end
        break unless data_local

        digest = Digest::SHA256.digest(data_local)
        sha256_mutex.synchronize do
          sha256_result = digest
          sha256_cv.signal
        end
      end
    end
    worker.abort_on_exception = false

    # Warmup persistent worker
    3.times do
      sha256_mutex.synchronize do
        sha256_request = data
        sha256_result = nil
        sha256_cv.signal
        sha256_cv.wait(sha256_mutex) until sha256_result
        sha256_result = nil
      end
    end

    # Persistent worker
    t_persist = Benchmark.measure do
      n.times do
        sha256_mutex.synchronize do
          sha256_request = data
          sha256_result = nil
          sha256_cv.signal
          sha256_cv.wait(sha256_mutex) until sha256_result
          sha256_result = nil
        end
      end
    end

    sync_ms = t_sync.real / n * 1000
    persist_ms = t_persist.real / n * 1000
    sync_mbps = (size.to_f / t_sync.real * n / 1_048_576).round(1)
    persist_mbps = (size.to_f / t_persist.real * n / 1_048_576).round(1)
    imp = ((sync_ms - persist_ms) / sync_ms * 100).round(1)

    comp_rows << {
      "Size" => label,
      "Sync(ms)" => sync_ms.round(1),
      "Sync MB/s" => sync_mbps,
      "Worker(ms)" => persist_ms.round(1),
      "Worker MB/s" => persist_mbps,
      "Δ" => "#{imp.positive? ? '+' : ''}#{imp}%",
    }
  end
  print_stats_table(comp_rows)
end

# ── End-to-End: Full OLD vs Full NEW with parallel SHA-256 ──

safe_bench("End-to-End: OLD vs NEW with parallel SHA-256") do
  comp_rows = []
  SIZES.each do |label, size|
    data = Random.bytes(size)
    n = 20
    key = HuggingFaceStorage::XetHasher::DATA_KEY

    # Warmup: OLD path
    3.times do
      chunk_ranges = hasher.cdc_chunk(data)
      chunk_data = chunk_ranges.map { |s, e| data.byteslice(s, e - s) }
      chunk_lengths = chunk_data.map(&:bytesize)
      chunk_hashes = hasher.batch_blake3_keyed(key, chunk_data, num_threads: 4)
      chunks_info = chunk_hashes.zip(chunk_lengths)
      xorb_hash = hasher.compute_xorb_hash(chunks_info)
      file_hash = hasher.compute_file_hash(xorb_hash)
      sha256 = Digest::SHA256.digest(data)
      serialized = serializer.serialize_xorb(chunk_data)
      rh = hasher.compute_verification_hash(chunk_hashes)
      rep = [{ xorb_hash: xorb_hash, index_start: 0, index_end: chunk_hashes.length,
               length: chunk_lengths.sum, range_hash: rh }]
      serializer.build_shard(file_hash: file_hash, representation: rep, chunk_hashes: chunk_hashes,
                             chunk_lengths: chunk_lengths, xorb_hash: xorb_hash,
                             xorb_serialized_size: serialized.bytesize, sha256: sha256)
    end

    # OLD path
    t_old = Benchmark.measure do
      n.times do
        chunk_ranges = hasher.cdc_chunk(data)
        chunk_data = chunk_ranges.map { |s, e| data.byteslice(s, e - s) }
        chunk_lengths = chunk_data.map(&:bytesize)
        chunk_hashes = hasher.batch_blake3_keyed(key, chunk_data, num_threads: 4)
        chunks_info = chunk_hashes.zip(chunk_lengths)
        xorb_hash = hasher.compute_xorb_hash(chunks_info)
        file_hash = hasher.compute_file_hash(xorb_hash)
        sha256 = Digest::SHA256.digest(data)
        serialized = serializer.serialize_xorb(chunk_data)
        rh = hasher.compute_verification_hash(chunk_hashes)
        rep = [{ xorb_hash: xorb_hash, index_start: 0, index_end: chunk_hashes.length,
                 length: chunk_lengths.sum, range_hash: rh }]
        serializer.build_shard(file_hash: file_hash, representation: rep, chunk_hashes: chunk_hashes,
                               chunk_lengths: chunk_lengths, xorb_hash: xorb_hash,
                               xorb_serialized_size: serialized.bytesize, sha256: sha256)
      end
    end

    # Warmup: NEW path with parallel SHA-256
    3.times do
      sha256_digest = Digest::SHA256.digest(data)
      chunk_ranges, hashes_concat = hasher.cdc_and_hash_native(data)
      chunk_hashes = hashes_concat.unpack("a32" * (hashes_concat.bytesize / 32))
      chunk_lengths = chunk_ranges.map { |s, e| e - s }
      xorb_hash = hasher.compute_xorb_hash(chunk_hashes, chunk_lengths)
      file_hash = hasher.compute_file_hash(xorb_hash)
      serialized = serializer.serialize_xorb_from_ranges(data, chunk_ranges)
      rh = hasher.compute_verification_hash(chunk_hashes)
      rep = [{ xorb_hash: xorb_hash, index_start: 0, index_end: chunk_hashes.length,
               length: chunk_lengths.sum, range_hash: rh }]
      serializer.build_shard(file_hash: file_hash, representation: rep, chunk_hashes: chunk_hashes,
                             chunk_lengths: chunk_lengths, xorb_hash: xorb_hash,
                             xorb_serialized_size: serialized.bytesize, sha256: sha256_digest)
    end

    # NEW path with parallel SHA-256
    t_new = Benchmark.measure do
      n.times do
        sha256_digest = Digest::SHA256.digest(data)
        chunk_ranges, hashes_concat = hasher.cdc_and_hash_native(data)
        chunk_hashes = hashes_concat.unpack("a32" * (hashes_concat.bytesize / 32))
        chunk_lengths = chunk_ranges.map { |s, e| e - s }
        xorb_hash = hasher.compute_xorb_hash(chunk_hashes, chunk_lengths)
        file_hash = hasher.compute_file_hash(xorb_hash)
        serialized = serializer.serialize_xorb_from_ranges(data, chunk_ranges)
        rh = hasher.compute_verification_hash(chunk_hashes)
        rep = [{ xorb_hash: xorb_hash, index_start: 0, index_end: chunk_hashes.length,
                 length: chunk_lengths.sum, range_hash: rh }]
        serializer.build_shard(file_hash: file_hash, representation: rep, chunk_hashes: chunk_hashes,
                               chunk_lengths: chunk_lengths, xorb_hash: xorb_hash,
                               xorb_serialized_size: serialized.bytesize, sha256: sha256_digest)
      end
    end

    old_ms = t_old.real / n * 1000
    new_ms = t_new.real / n * 1000
    old_mbps = (size.to_f / t_old.real * n / 1_048_576).round(1)
    new_mbps = (size.to_f / t_new.real * n / 1_048_576).round(1)
    imp = ((new_mbps - old_mbps) / old_mbps * 100).round(1)

    comp_rows << {
      "Size" => label,
      "OLD(ms)" => old_ms.round(1),
      "OLD MB/s" => old_mbps,
      "NEW(ms)" => new_ms.round(1),
      "NEW MB/s" => new_mbps,
      "Δ" => "#{imp.positive? ? '+' : ''}#{imp}%",
    }
  end
  print_stats_table(comp_rows)
end

puts
puts "Done."
