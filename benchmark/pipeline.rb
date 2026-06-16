# frozen_string_literal: true

require_relative "helper"

include BenchmarkHelper

hasher = HuggingFaceStorage::XetHasher.new
serializer = HuggingFaceStorage::XetSerializer.new(hasher)
key = HuggingFaceStorage::XetHasher::DATA_KEY

print_header("Pipeline Bottleneck Analysis")

# ── CDC Scaling ──

safe_bench("CDC Scaling: Throughput vs Data Size") do
  stats_rows = []
  SIZES.each do |label, size|
    data = Random.bytes(size)
    warmup { hasher.cdc_chunk(data) }
    stats = statistical_run(data_size: size) { hasher.cdc_chunk(data) }
    chunks = hasher.cdc_chunk(data)
    avg_chunk = chunks.sum { |s, e| e - s }.to_f / chunks.size
    stats_rows << {
      "Size" => label,
      "Iters" => stats[:iterations],
      "Min(s)" => stats[:min].round(4),
      "Max(s)" => stats[:max].round(4),
      "Avg(s)" => stats[:avg].round(4),
      "Med(s)" => stats[:median].round(4),
      "P95(s)" => stats[:p95].round(4),
      "Chunks" => chunks.size,
      "Avg Chunk" => "#{avg_chunk.round(0)} B",
      "MB/s" => stats[:throughput_mbps],
    }
  end
  print_stats_table(stats_rows)
end

# ── Blake3 Scaling: Sequential vs Batch vs Thread Counts ──

safe_bench("Blake3 Scaling: Sequential vs Batch (1/2/4/8 threads)") do
  test_sizes = { "1 MB" => 1_048_576, "10 MB" => 10_485_760 }
  thread_counts = [1, 2, 4, 8]

  test_sizes.each do |label, size|
    data = Random.bytes(size)
    chunk_ranges = hasher.cdc_chunk(data)
    chunks_data = chunk_ranges.map { |s, e| data.byteslice(s, e - s) }

    puts "\n  [#{label} - #{chunks_data.size} chunks]"

    rows = []

    # Sequential
    warmup { chunks_data.each { |cd| hasher.blake3_keyed(key, cd) } }
    seq_stats = statistical_run(data_size: size) do
      chunks_data.each { |cd| hasher.blake3_keyed(key, cd) }
    end
    rows << {
      "Method" => "Sequential",
      "Threads" => 1,
      "Min(s)" => seq_stats[:min].round(4),
      "Max(s)" => seq_stats[:max].round(4),
      "Avg(s)" => seq_stats[:avg].round(4),
      "MB/s" => seq_stats[:throughput_mbps],
    }

    # Batch with different thread counts
    thread_counts.each do |num_threads|
      warmup { hasher.batch_blake3_keyed(key, chunks_data, num_threads: num_threads) }
      batch_stats = statistical_run(data_size: size) do
        hasher.batch_blake3_keyed(key, chunks_data, num_threads: num_threads)
      end
      rows << {
        "Method" => "Batch",
        "Threads" => num_threads,
        "Min(s)" => batch_stats[:min].round(4),
        "Max(s)" => batch_stats[:max].round(4),
        "Avg(s)" => batch_stats[:avg].round(4),
        "MB/s" => batch_stats[:throughput_mbps],
      }
    end

    print_stats_table(rows)

    # Find optimal thread count
    batch_rows = rows.select { |r| r["Method"] == "Batch" }
    optimal = batch_rows.max_by { |r| r["MB/s"] }
    puts "  Optimal: #{optimal["Threads"]} threads (#{optimal["MB/s"]} MB/s)"
  end
end

# ── Serialize Scaling: OLD vs NEW ──

safe_bench("Serialize Scaling: serialize_xorb vs serialize_xorb_from_ranges") do
  stats_rows = []
  SIZES.each do |label, size|
    data = Random.bytes(size)
    chunk_ranges = hasher.cdc_chunk(data)
    chunks_data = chunk_ranges.map { |s, e| data.byteslice(s, e - s) }

    # OLD: serialize_xorb (with copies)
    warmup { serializer.serialize_xorb(chunks_data) }
    old_stats = statistical_run(data_size: size) do
      serializer.serialize_xorb(chunks_data)
    end

    # NEW: serialize_xorb_from_ranges (no copies)
    if serializer.respond_to?(:serialize_xorb_from_ranges)
      warmup { serializer.serialize_xorb_from_ranges(data, chunk_ranges) }
      new_stats = statistical_run(data_size: size) do
        serializer.serialize_xorb_from_ranges(data, chunk_ranges)
      end
      improvement = ((new_stats[:throughput_mbps] - old_stats[:throughput_mbps]) / old_stats[:throughput_mbps] * 100).round(1)
    else
      new_stats = nil
      improvement = "N/A"
    end

    stats_rows << {
      "Size" => label,
      "OLD Avg(s)" => old_stats[:avg].round(4),
      "OLD MB/s" => old_stats[:throughput_mbps],
      "NEW Avg(s)" => new_stats ? new_stats[:avg].round(4) : "N/A",
      "NEW MB/s" => new_stats ? new_stats[:throughput_mbps] : "N/A",
      "Improve" => new_stats ? "#{improvement.positive? ? '+' : ''}#{improvement}%" : "N/A",
    }
  end
  print_stats_table(stats_rows)
end

# ── Full Pipeline Comparison: OLD vs NEW (detailed) ──

safe_bench("Full Pipeline: OLD vs NEW (detailed)") do
  stats_rows = []
  SIZES.each do |label, size|
    data = Random.bytes(size)

    # OLD pipeline
    warmup do
      cr = hasher.cdc_chunk(data)
      cd = cr.map { |s, e| data.byteslice(s, e - s) }
      cl = cd.map(&:bytesize)
      ch = hasher.batch_blake3_keyed(key, cd, num_threads: DEFAULT_THREADS)
      ci = ch.zip(cl)
      xh = hasher.compute_xorb_hash(ci)
      fh = hasher.compute_file_hash(xh)
      s256 = Digest::SHA256.digest(data)
      serializer.serialize_xorb(cd)
      rh = hasher.compute_verification_hash(ch)
      rep = [{ xorb_hash: xh, index_start: 0, index_end: ch.length, length: cl.sum,
               range_hash: rh }]
      serializer.build_shard(file_hash: fh, representation: rep, chunk_hashes: ch,
                             chunk_lengths: cl, xorb_hash: xh,
                             xorb_serialized_size: serializer.serialize_xorb(cd).bytesize, sha256: s256)
    end
    old_stats = statistical_run(data_size: size) do
      cr = hasher.cdc_chunk(data)
      cd = cr.map { |s, e| data.byteslice(s, e - s) }
      cl = cd.map(&:bytesize)
      ch = hasher.batch_blake3_keyed(key, cd, num_threads: DEFAULT_THREADS)
      ci = ch.zip(cl)
      xh = hasher.compute_xorb_hash(ci)
      fh = hasher.compute_file_hash(xh)
      s256 = Digest::SHA256.digest(data)
      serialized = serializer.serialize_xorb(cd)
      rh = hasher.compute_verification_hash(ch)
      rep = [{ xorb_hash: xh, index_start: 0, index_end: ch.length, length: cl.sum,
               range_hash: rh }]
      serializer.build_shard(file_hash: fh, representation: rep, chunk_hashes: ch,
                             chunk_lengths: cl, xorb_hash: xh,
                             xorb_serialized_size: serialized.bytesize, sha256: s256)
    end

    # NEW pipeline: uses cdc_and_hash_native (combined CDC+Blake3 in C)
    if native_gearhash_available?
      warmup do
        chunk_ranges, hashes_concat = hasher.cdc_and_hash_native(data)
        chunk_hashes = hashes_concat.unpack("a32" * (hashes_concat.bytesize / 32))
        chunk_lengths = chunk_ranges.map { |s, e| e - s }
        xh = hasher.compute_xorb_hash(chunk_hashes, chunk_lengths)
        fh = hasher.compute_file_hash(xh)
        s256 = Digest::SHA256.digest(data)
        serializer.serialize_xorb_from_ranges(data, chunk_ranges)
        rh = hasher.compute_verification_hash(chunk_hashes)
        rep = [{ xorb_hash: xh, index_start: 0, index_end: chunk_hashes.length, length: chunk_lengths.sum,
                 range_hash: rh }]
        serializer.build_shard(file_hash: fh, representation: rep, chunk_hashes: chunk_hashes,
                               chunk_lengths: chunk_lengths, xorb_hash: xh,
                               xorb_serialized_size: serializer.serialize_xorb_from_ranges(data, chunk_ranges).bytesize,
                               sha256: s256)
      end
      new_stats = statistical_run(data_size: size) do
        chunk_ranges, hashes_concat = hasher.cdc_and_hash_native(data)
        chunk_hashes = hashes_concat.unpack("a32" * (hashes_concat.bytesize / 32))
        chunk_lengths = chunk_ranges.map { |s, e| e - s }
        xh = hasher.compute_xorb_hash(chunk_hashes, chunk_lengths)
        fh = hasher.compute_file_hash(xh)
        s256 = Digest::SHA256.digest(data)
        serialized = serializer.serialize_xorb_from_ranges(data, chunk_ranges)
        rh = hasher.compute_verification_hash(chunk_hashes)
        rep = [{ xorb_hash: xh, index_start: 0, index_end: chunk_hashes.length, length: chunk_lengths.sum,
                 range_hash: rh }]
        serializer.build_shard(file_hash: fh, representation: rep, chunk_hashes: chunk_hashes,
                               chunk_lengths: chunk_lengths, xorb_hash: xh,
                               xorb_serialized_size: serialized.bytesize, sha256: s256)
      end
      improvement = ((new_stats[:throughput_mbps] - old_stats[:throughput_mbps]) / old_stats[:throughput_mbps] * 100).round(1)
    else
      new_stats = nil
      improvement = "N/A"
    end

    stats_rows << {
      "Size" => label,
      "OLD Min(s)" => old_stats[:min].round(4),
      "OLD Max(s)" => old_stats[:max].round(4),
      "OLD Avg(s)" => old_stats[:avg].round(4),
      "OLD MB/s" => old_stats[:throughput_mbps],
      "NEW Min(s)" => new_stats ? new_stats[:min].round(4) : "N/A",
      "NEW Max(s)" => new_stats ? new_stats[:max].round(4) : "N/A",
      "NEW Avg(s)" => new_stats ? new_stats[:avg].round(4) : "N/A",
      "NEW MB/s" => new_stats ? new_stats[:throughput_mbps] : "N/A",
      "Improve" => new_stats ? "#{improvement.positive? ? '+' : ''}#{improvement}%" : "N/A",
    }
  end
  print_stats_table(stats_rows)
end

# ── Production Pipeline: Full Single-File Upload Path ──

safe_bench("Production Pipeline: full single-file upload path (OLD vs NEW)") do
  stats_rows = []
  SIZES.each do |label, size|
    data = Random.bytes(size)

    # OLD: separate CDC + batch Blake3 from slices
    warmup do
      cr = hasher.cdc_chunk(data)
      cd = cr.map { |s, e| data.byteslice(s, e - s) }
      cl = cd.map(&:bytesize)
      ch = hasher.batch_blake3_keyed(key, cd, num_threads: DEFAULT_THREADS)
      ci = ch.zip(cl)
      xh = hasher.compute_xorb_hash(ci)
      fh = hasher.compute_file_hash(xh)
      s256 = Digest::SHA256.digest(data)
      rh = hasher.compute_verification_hash(ch)
      serializer.serialize_xorb(cd)
      rep = [{ xorb_hash: xh, index_start: 0, index_end: ch.length, length: cl.sum, range_hash: rh }]
      serializer.build_shard(file_hash: fh, representation: rep, chunk_hashes: ch,
                             chunk_lengths: cl, xorb_hash: xh,
                             xorb_serialized_size: serializer.serialize_xorb(cd).bytesize, sha256: s256)
    end
    old_stats = statistical_run(data_size: size) do
      cr = hasher.cdc_chunk(data)
      cd = cr.map { |s, e| data.byteslice(s, e - s) }
      cl = cd.map(&:bytesize)
      ch = hasher.batch_blake3_keyed(key, cd, num_threads: DEFAULT_THREADS)
      ci = ch.zip(cl)
      xh = hasher.compute_xorb_hash(ci)
      fh = hasher.compute_file_hash(xh)
      s256 = Digest::SHA256.digest(data)
      serialized = serializer.serialize_xorb(cd)
      rh = hasher.compute_verification_hash(ch)
      rep = [{ xorb_hash: xh, index_start: 0, index_end: ch.length, length: cl.sum, range_hash: rh }]
      serializer.build_shard(file_hash: fh, representation: rep, chunk_hashes: ch,
                             chunk_lengths: cl, xorb_hash: xh,
                             xorb_serialized_size: serialized.bytesize, sha256: s256)
    end

    # NEW: cdc_and_hash_native + parallel SHA-256 + unpack + parallel arrays
    if native_gearhash_available?
      # Parallel SHA-256 thread (mimics production persistent worker)
      sha256_thread = data.bytesize > 256 * 1024 ? Thread.new { Digest::SHA256.digest(data) } : nil
      warmup do
        chunk_ranges, hashes_concat = hasher.cdc_and_hash_native(data)
        chunk_hashes = hashes_concat.unpack("a32" * (hashes_concat.bytesize / 32))
        chunk_lengths = chunk_ranges.map { |s, e| e - s }
        xh = hasher.compute_xorb_hash(chunk_hashes, chunk_lengths)
        fh = hasher.compute_file_hash(xh)
        s256 = sha256_thread ? sha256_thread.value : Digest::SHA256.digest(data)
        serializer.serialize_xorb_from_ranges(data, chunk_ranges)
        rh = hasher.compute_verification_hash(chunk_hashes)
        rep = [{ xorb_hash: xh, index_start: 0, index_end: chunk_hashes.length, length: chunk_lengths.sum,
                 range_hash: rh }]
        serializer.build_shard(file_hash: fh, representation: rep, chunk_hashes: chunk_hashes,
                               chunk_lengths: chunk_lengths, xorb_hash: xh,
                               xorb_serialized_size: serializer.serialize_xorb_from_ranges(data, chunk_ranges).bytesize,
                               sha256: s256)
      end
      new_stats = statistical_run(data_size: size) do
        chunk_ranges, hashes_concat = hasher.cdc_and_hash_native(data)
        chunk_hashes = hashes_concat.unpack("a32" * (hashes_concat.bytesize / 32))
        chunk_lengths = chunk_ranges.map { |s, e| e - s }
        xh = hasher.compute_xorb_hash(chunk_hashes, chunk_lengths)
        fh = hasher.compute_file_hash(xh)
        s256 = sha256_thread ? sha256_thread.value : Digest::SHA256.digest(data)
        serialized = serializer.serialize_xorb_from_ranges(data, chunk_ranges)
        rh = hasher.compute_verification_hash(chunk_hashes)
        rep = [{ xorb_hash: xh, index_start: 0, index_end: chunk_hashes.length, length: chunk_lengths.sum,
                 range_hash: rh }]
        serializer.build_shard(file_hash: fh, representation: rep, chunk_hashes: chunk_hashes,
                               chunk_lengths: chunk_lengths, xorb_hash: xh,
                               xorb_serialized_size: serialized.bytesize, sha256: s256)
        sha256_thread = Thread.new { Digest::SHA256.digest(data) } if data.bytesize > 256 * 1024
      end
      improvement = ((new_stats[:throughput_mbps] - old_stats[:throughput_mbps]) / old_stats[:throughput_mbps] * 100).round(1)
    else
      new_stats = nil
      improvement = "N/A"
    end

    stats_rows << {
      "Size" => label,
      "OLD Avg(s)" => old_stats[:avg].round(4),
      "OLD MB/s" => old_stats[:throughput_mbps],
      "NEW Avg(s)" => new_stats ? new_stats[:avg].round(4) : "N/A",
      "NEW MB/s" => new_stats ? new_stats[:throughput_mbps] : "N/A",
      "Improve" => new_stats ? "#{improvement.positive? ? '+' : ''}#{improvement}%" : "N/A",
    }
  end
  print_stats_table(stats_rows)
end

# ── Bottleneck Summary ──

safe_bench("Bottleneck Summary") do
  puts "\n  Analyzing 10 MB pipeline..."
  size = 10_485_760
  data = Random.bytes(size)
  chunk_ranges = hasher.cdc_chunk(data)
  chunks_data = chunk_ranges.map { |s, e| data.byteslice(s, e - s) }
  chunk_lengths = chunks_data.map(&:bytesize)

  # CDC (Ruby)
  warmup { hasher.cdc_chunk(data) }
  cdc_stats = statistical_run(data_size: size) { hasher.cdc_chunk(data) }

  # Blake3 batch
  warmup { hasher.batch_blake3_keyed(key, chunks_data, num_threads: DEFAULT_THREADS) }
  blake3_stats = statistical_run(data_size: size) do
    hasher.batch_blake3_keyed(key, chunks_data, num_threads: DEFAULT_THREADS)
  end

  # cdc_and_hash_native (combined CDC + Blake3 in C)
  if native_gearhash_available?
    warmup { hasher.cdc_and_hash_native(data) }
    native_stats = statistical_run(data_size: size) { hasher.cdc_and_hash_native(data) }
  end

  # Serialize OLD
  warmup { serializer.serialize_xorb(chunks_data) }
  serialize_old_stats = statistical_run(data_size: size) do
    serializer.serialize_xorb(chunks_data)
  end

  # Serialize NEW
  if serializer.respond_to?(:serialize_xorb_from_ranges)
    warmup { serializer.serialize_xorb_from_ranges(data, chunk_ranges) }
    serialize_new_stats = statistical_run(data_size: size) do
      serializer.serialize_xorb_from_ranges(data, chunk_ranges)
    end
  end

  # Full OLD
  warmup do
    cr = hasher.cdc_chunk(data)
    cd = cr.map { |s, e| data.byteslice(s, e - s) }
    cl = cd.map(&:bytesize)
    ch = hasher.batch_blake3_keyed(key, cd, num_threads: DEFAULT_THREADS)
    ci = ch.zip(cl)
    xh = hasher.compute_xorb_hash(ci)
    fh = hasher.compute_file_hash(xh)
    s256 = Digest::SHA256.digest(data)
    serializer.serialize_xorb(cd)
    rh = hasher.compute_verification_hash(ch)
    rep = [{ xorb_hash: xh, index_start: 0, index_end: ch.length, length: cl.sum,
             range_hash: rh }]
    serializer.build_shard(file_hash: fh, representation: rep, chunk_hashes: ch,
                           chunk_lengths: cl, xorb_hash: xh,
                           xorb_serialized_size: serializer.serialize_xorb(cd).bytesize, sha256: s256)
  end
  old_full_stats = statistical_run(data_size: size) do
    cr = hasher.cdc_chunk(data)
    cd = cr.map { |s, e| data.byteslice(s, e - s) }
    cl = cd.map(&:bytesize)
    ch = hasher.batch_blake3_keyed(key, cd, num_threads: DEFAULT_THREADS)
    ci = ch.zip(cl)
    xh = hasher.compute_xorb_hash(ci)
    fh = hasher.compute_file_hash(xh)
    s256 = Digest::SHA256.digest(data)
    serialized = serializer.serialize_xorb(cd)
    rh = hasher.compute_verification_hash(ch)
    rep = [{ xorb_hash: xh, index_start: 0, index_end: ch.length, length: cl.sum,
             range_hash: rh }]
    serializer.build_shard(file_hash: fh, representation: rep, chunk_hashes: ch,
                           chunk_lengths: cl, xorb_hash: xh,
                           xorb_serialized_size: serialized.bytesize, sha256: s256)
  end

  # Full NEW (cdc_and_hash_native + parallel SHA-256 + unpack)
  if native_gearhash_available?
    warmup do
      chunk_ranges, hashes_concat = hasher.cdc_and_hash_native(data)
      chunk_hashes = hashes_concat.unpack("a32" * (hashes_concat.bytesize / 32))
      chunk_lens = chunk_ranges.map { |s, e| e - s }
      xh = hasher.compute_xorb_hash(chunk_hashes, chunk_lens)
      fh = hasher.compute_file_hash(xh)
      s256 = Digest::SHA256.digest(data)
      serializer.serialize_xorb_from_ranges(data, chunk_ranges)
      rh = hasher.compute_verification_hash(chunk_hashes)
      rep = [{ xorb_hash: xh, index_start: 0, index_end: chunk_hashes.length, length: chunk_lens.sum,
               range_hash: rh }]
      serializer.build_shard(file_hash: fh, representation: rep, chunk_hashes: chunk_hashes,
                             chunk_lengths: chunk_lens, xorb_hash: xh,
                             xorb_serialized_size: serializer.serialize_xorb_from_ranges(data, chunk_ranges).bytesize,
                             sha256: s256)
    end
    new_full_stats = statistical_run(data_size: size) do
      chunk_ranges, hashes_concat = hasher.cdc_and_hash_native(data)
      chunk_hashes = hashes_concat.unpack("a32" * (hashes_concat.bytesize / 32))
      chunk_lens = chunk_ranges.map { |s, e| e - s }
      xh = hasher.compute_xorb_hash(chunk_hashes, chunk_lens)
      fh = hasher.compute_file_hash(xh)
      s256 = Digest::SHA256.digest(data)
      serialized = serializer.serialize_xorb_from_ranges(data, chunk_ranges)
      rh = hasher.compute_verification_hash(chunk_hashes)
      rep = [{ xorb_hash: xh, index_start: 0, index_end: chunk_hashes.length, length: chunk_lens.sum,
               range_hash: rh }]
      serializer.build_shard(file_hash: fh, representation: rep, chunk_hashes: chunk_hashes,
                             chunk_lengths: chunk_lens, xorb_hash: xh,
                             xorb_serialized_size: serialized.bytesize, sha256: s256)
    end
  end

  # Print summary
  breakdown_rows = [
    {
      "Step" => "CDC (Ruby)",
      "Min(s)" => cdc_stats[:min].round(4),
      "Max(s)" => cdc_stats[:max].round(4),
      "Avg(s)" => cdc_stats[:avg].round(4),
      "MB/s" => cdc_stats[:throughput_mbps],
    },
    {
      "Step" => "Blake3 Batch",
      "Min(s)" => blake3_stats[:min].round(4),
      "Max(s)" => blake3_stats[:max].round(4),
      "Avg(s)" => blake3_stats[:avg].round(4),
      "MB/s" => blake3_stats[:throughput_mbps],
    },
  ]

  if native_gearhash_available?
    breakdown_rows << {
      "Step" => "cdc_and_hash_native",
      "Min(s)" => native_stats[:min].round(4),
      "Max(s)" => native_stats[:max].round(4),
      "Avg(s)" => native_stats[:avg].round(4),
      "MB/s" => native_stats[:throughput_mbps],
    }
  end

  breakdown_rows << {
    "Step" => "Serialize OLD",
    "Min(s)" => serialize_old_stats[:min].round(4),
    "Max(s)" => serialize_old_stats[:max].round(4),
    "Avg(s)" => serialize_old_stats[:avg].round(4),
    "MB/s" => serialize_old_stats[:throughput_mbps],
  }

  if serialize_new_stats
    breakdown_rows << {
      "Step" => "Serialize NEW",
      "Min(s)" => serialize_new_stats[:min].round(4),
      "Max(s)" => serialize_new_stats[:max].round(4),
      "Avg(s)" => serialize_new_stats[:avg].round(4),
      "MB/s" => serialize_new_stats[:throughput_mbps],
    }
  end

  breakdown_rows << {
    "Step" => "Full OLD",
    "Min(s)" => old_full_stats[:min].round(4),
    "Max(s)" => old_full_stats[:max].round(4),
    "Avg(s)" => old_full_stats[:avg].round(4),
    "MB/s" => old_full_stats[:throughput_mbps],
  }

  if new_full_stats
    breakdown_rows << {
      "Step" => "Full NEW",
      "Min(s)" => new_full_stats[:min].round(4),
      "Max(s)" => new_full_stats[:max].round(4),
      "Avg(s)" => new_full_stats[:avg].round(4),
      "MB/s" => new_full_stats[:throughput_mbps],
    }
  end

  print_breakdown_table(breakdown_rows)

  # Identify bottleneck
  component_stats = [cdc_stats, blake3_stats, serialize_old_stats]
  bottleneck = component_stats.min_by { |s| s[:throughput_mbps] }
  bottleneck_name = case bottleneck
                    when cdc_stats then "CDC"
                    when blake3_stats then "Blake3"
                    when serialize_old_stats then "Serialize"
                    end
  total_time = old_full_stats[:avg]
  bottleneck_pct = (bottleneck[:avg] / total_time * 100).round(1)

  puts "\n  === Analysis ==="
  puts "  Bottleneck: #{bottleneck_name} (#{bottleneck[:throughput_mbps]} MB/s, #{bottleneck_pct}% of total time)"
  puts "  Full pipeline: OLD=#{old_full_stats[:throughput_mbps]} MB/s, NEW=#{new_full_stats ? new_full_stats[:throughput_mbps] : 'N/A'} MB/s"

  if new_full_stats
    improvement = ((new_full_stats[:throughput_mbps] - old_full_stats[:throughput_mbps]) / old_full_stats[:throughput_mbps] * 100).round(1)
    puts "  NEW improvement: #{improvement.positive? ? '+' : ''}#{improvement}% over OLD"
    puts "  Recommendation: #{improvement > 5 ? 'NEW pipeline is beneficial' : 'Improvement is marginal, consider keeping OLD for simplicity'}"
  end
end

puts
puts "Done."
