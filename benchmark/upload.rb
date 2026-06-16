# frozen_string_literal: true

require_relative "helper"

include BenchmarkHelper

hasher = HuggingFaceStorage::XetHasher.new
serializer = HuggingFaceStorage::XetSerializer.new(hasher)
key = HuggingFaceStorage::XetHasher::DATA_KEY

print_header("Upload Pipeline Benchmark")

# ── CDC Chunking ──

safe_bench("CDC Chunking") do
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
      "Chunks" => chunks.size,
      "Avg Chunk" => "#{avg_chunk.round(0)} B",
      "MB/s" => stats[:throughput_mbps],
    }
  end
  print_stats_table(stats_rows)
end

# ── CDC Comparison: Ruby vs Native ──

safe_bench("CDC Comparison: Ruby vs Native") do
  comp_rows = []
  SIZES.each do |label, size|
    data = Random.bytes(size)

    # Adaptive iteration count: Ruby CDC is ~2 MB/s, cap large sizes to avoid timeout
    ruby_iters = size > 1_048_576 ? 3 : DEFAULT_ITERATIONS
    warmup(count: 3) { hasher.cdc_chunk_ruby(data) } if size <= 1_048_576
    ruby_stats = statistical_run(data_size: size, iterations: ruby_iters) { hasher.cdc_chunk_ruby(data) }

    if native_gearhash_available?
      warmup { hasher.cdc_chunk(data) }
      native_stats = statistical_run(data_size: size) { hasher.cdc_chunk(data) }
      speedup = (native_stats[:throughput_mbps] / ruby_stats[:throughput_mbps]).round(0)
    else
      native_stats = nil
      speedup = "N/A"
    end

    comp_rows << {
      "Size" => label,
      "Ruby Avg(s)" => ruby_stats[:avg].round(4),
      "Ruby MB/s" => ruby_stats[:throughput_mbps],
      "Native Avg(s)" => native_stats ? native_stats[:avg].round(4) : "N/A",
      "Native MB/s" => native_stats ? native_stats[:throughput_mbps] : "N/A",
      "Speedup" => native_gearhash_available? ? "#{speedup}x" : "N/A",
    }
  end
  print_stats_table(comp_rows)
end

# ── Sequential Blake3 ──

safe_bench("Sequential Blake3 (blake3_keyed per chunk)") do
  stats_rows = []
  SIZES.each do |label, size|
    data = Random.bytes(size)
    chunk_ranges = hasher.cdc_chunk(data)
    chunks_data = chunk_ranges.map { |s, e| data.byteslice(s, e - s) }

    warmup { chunks_data.each { |cd| hasher.blake3_keyed(key, cd) } }
    stats = statistical_run(data_size: size) do
      chunks_data.each { |cd| hasher.blake3_keyed(key, cd) }
    end
    stats_rows << {
      "Size" => label,
      "Chunks" => chunks_data.size,
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

# ── Batch Blake3 ──

safe_bench("Batch Blake3 (batch_blake3_keyed, #{DEFAULT_THREADS} threads)") do
  stats_rows = []
  SIZES.each do |label, size|
    data = Random.bytes(size)
    chunk_ranges = hasher.cdc_chunk(data)
    chunks_data = chunk_ranges.map { |s, e| data.byteslice(s, e - s) }

    begin
      warmup { hasher.batch_blake3_keyed(key, chunks_data, num_threads: DEFAULT_THREADS) }
      stats = statistical_run(data_size: size) do
        hasher.batch_blake3_keyed(key, chunks_data, num_threads: DEFAULT_THREADS)
      end
      stats_rows << {
        "Size" => label,
        "Chunks" => chunks_data.size,
        "Iters" => stats[:iterations],
        "Min(s)" => stats[:min].round(4),
        "Max(s)" => stats[:max].round(4),
        "Avg(s)" => stats[:avg].round(4),
        "Med(s)" => stats[:median].round(4),
        "MB/s" => stats[:throughput_mbps],
      }
    rescue StandardError => e
      puts "  ERROR for #{label}: #{e.class}: #{e.message}"
      puts "  #{e.backtrace.first(2).join("\n  ")}" if e.backtrace
    end
  end
  print_stats_table(stats_rows) unless stats_rows.empty?
end

# ── Pipeline Breakdown: Step-by-Step ──

safe_bench("Pipeline Breakdown: Step-by-Step") do
  SIZES.each do |label, size|
    data = Random.bytes(size)
    chunk_ranges = hasher.cdc_chunk(data)
    chunks_data = chunk_ranges.map { |s, e| data.byteslice(s, e - s) }
    chunk_lengths = chunks_data.map(&:bytesize)

    puts "\n  [#{label}]"

    # CDC only
    warmup { hasher.cdc_chunk(data) }
    cdc_stats = statistical_run(data_size: size) { hasher.cdc_chunk(data) }

    # Blake3 sequential only
    warmup { chunks_data.each { |cd| hasher.blake3_keyed(key, cd) } }
    blake3_seq_stats = statistical_run(data_size: size) do
      chunks_data.each { |cd| hasher.blake3_keyed(key, cd) }
    end

    # Blake3 batch only
    warmup { hasher.batch_blake3_keyed(key, chunks_data, num_threads: DEFAULT_THREADS) }
    blake3_batch_stats = statistical_run(data_size: size) do
      hasher.batch_blake3_keyed(key, chunks_data, num_threads: DEFAULT_THREADS)
    end

    # Serialize only (OLD: with copies)
    warmup { serializer.serialize_xorb(chunks_data) }
    serialize_old_stats = statistical_run(data_size: size) do
      serializer.serialize_xorb(chunks_data)
    end

    # Serialize only (NEW: from_ranges, no copies)
    if serializer.respond_to?(:serialize_xorb_from_ranges)
      warmup { serializer.serialize_xorb_from_ranges(data, chunk_ranges) }
      serialize_new_stats = statistical_run(data_size: size) do
        serializer.serialize_xorb_from_ranges(data, chunk_ranges)
      end
    end

    # Full OLD pipeline
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
      rep = [{ xorb_hash: xh, index_start: 0, index_end: ch.length, length: cl.sum,
               range_hash: hasher.compute_verification_hash(ch) }]
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
      rep = [{ xorb_hash: xh, index_start: 0, index_end: ch.length, length: cl.sum,
               range_hash: hasher.compute_verification_hash(ch) }]
      serializer.build_shard(file_hash: fh, representation: rep, chunk_hashes: ch,
                             chunk_lengths: cl, xorb_hash: xh,
                             xorb_serialized_size: serialized.bytesize, sha256: s256)
    end

    # Full NEW pipeline
    if serializer.respond_to?(:serialize_xorb_from_ranges)
      warmup do
        cr = hasher.cdc_chunk(data)
        ch = hasher.batch_blake3_keyed_from_ranges(key, data, cr, num_threads: DEFAULT_THREADS)
        cl = cr.map { |s, e| e - s }
        ci = ch.zip(cl)
        xh = hasher.compute_xorb_hash(ci)
        fh = hasher.compute_file_hash(xh)
        s256 = Digest::SHA256.digest(data)
        serializer.serialize_xorb_from_ranges(data, cr)
        rep = [{ xorb_hash: xh, index_start: 0, index_end: ch.length, length: cl.sum,
                 range_hash: hasher.compute_verification_hash(ch) }]
        serializer.build_shard(file_hash: fh, representation: rep, chunk_hashes: ch,
                               chunk_lengths: cl, xorb_hash: xh,
                               xorb_serialized_size: serializer.serialize_xorb_from_ranges(data, cr).bytesize,
                               sha256: s256)
      end
      new_full_stats = statistical_run(data_size: size) do
        cr = hasher.cdc_chunk(data)
        ch = hasher.batch_blake3_keyed_from_ranges(key, data, cr, num_threads: DEFAULT_THREADS)
        cl = cr.map { |s, e| e - s }
        ci = ch.zip(cl)
        xh = hasher.compute_xorb_hash(ci)
        fh = hasher.compute_file_hash(xh)
        s256 = Digest::SHA256.digest(data)
        serialized = serializer.serialize_xorb_from_ranges(data, cr)
        rep = [{ xorb_hash: xh, index_start: 0, index_end: ch.length, length: cl.sum,
                 range_hash: hasher.compute_verification_hash(ch) }]
        serializer.build_shard(file_hash: fh, representation: rep, chunk_hashes: ch,
                               chunk_lengths: cl, xorb_hash: xh,
                               xorb_serialized_size: serialized.bytesize, sha256: s256)
      end
    end

    # Print breakdown table
    breakdown_rows = [
      {
        "Step" => "CDC",
        "Min(s)" => cdc_stats[:min].round(4),
        "Max(s)" => cdc_stats[:max].round(4),
        "Avg(s)" => cdc_stats[:avg].round(4),
        "MB/s" => cdc_stats[:throughput_mbps],
      },
      {
        "Step" => "Blake3 Seq",
        "Min(s)" => blake3_seq_stats[:min].round(4),
        "Max(s)" => blake3_seq_stats[:max].round(4),
        "Avg(s)" => blake3_seq_stats[:avg].round(4),
        "MB/s" => blake3_seq_stats[:throughput_mbps],
      },
      {
        "Step" => "Blake3 Batch",
        "Min(s)" => blake3_batch_stats[:min].round(4),
        "Max(s)" => blake3_batch_stats[:max].round(4),
        "Avg(s)" => blake3_batch_stats[:avg].round(4),
        "MB/s" => blake3_batch_stats[:throughput_mbps],
      },
      {
        "Step" => "Serialize OLD",
        "Min(s)" => serialize_old_stats[:min].round(4),
        "Max(s)" => serialize_old_stats[:max].round(4),
        "Avg(s)" => serialize_old_stats[:avg].round(4),
        "MB/s" => serialize_old_stats[:throughput_mbps],
      },
    ]

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
    steps = breakdown_rows.select { |r| r["Step"].start_with?("Full") }.empty? ? breakdown_rows[0..2] : breakdown_rows[0..2]
    bottleneck = steps.min_by { |r| r["MB/s"] }
    puts "  Bottleneck: #{bottleneck["Step"]} (#{bottleneck["MB/s"]} MB/s)"

    # NEW vs OLD improvement
    if new_full_stats
      improvement = ((new_full_stats[:throughput_mbps] - old_full_stats[:throughput_mbps]) / old_full_stats[:throughput_mbps] * 100).round(1)
      puts "  NEW improvement: #{improvement.positive? ? '+' : ''}#{improvement}% over OLD"
    end
  end
end

# ── OLD vs NEW Comparison (detailed) ──

safe_bench("OLD vs NEW Comparison") do
  comp_rows = []
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
      rep = [{ xorb_hash: xh, index_start: 0, index_end: ch.length, length: cl.sum,
               range_hash: hasher.compute_verification_hash(ch) }]
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
      rep = [{ xorb_hash: xh, index_start: 0, index_end: ch.length, length: cl.sum,
               range_hash: hasher.compute_verification_hash(ch) }]
      serializer.build_shard(file_hash: fh, representation: rep, chunk_hashes: ch,
                             chunk_lengths: cl, xorb_hash: xh,
                             xorb_serialized_size: serialized.bytesize, sha256: s256)
    end

    # NEW pipeline
    if serializer.respond_to?(:serialize_xorb_from_ranges)
      warmup do
        cr = hasher.cdc_chunk(data)
        ch = hasher.batch_blake3_keyed_from_ranges(key, data, cr, num_threads: DEFAULT_THREADS)
        cl = cr.map { |s, e| e - s }
        ci = ch.zip(cl)
        xh = hasher.compute_xorb_hash(ci)
        fh = hasher.compute_file_hash(xh)
        s256 = Digest::SHA256.digest(data)
        serializer.serialize_xorb_from_ranges(data, cr)
        rep = [{ xorb_hash: xh, index_start: 0, index_end: ch.length, length: cl.sum,
                 range_hash: hasher.compute_verification_hash(ch) }]
        serializer.build_shard(file_hash: fh, representation: rep, chunk_hashes: ch,
                               chunk_lengths: cl, xorb_hash: xh,
                               xorb_serialized_size: serializer.serialize_xorb_from_ranges(data, cr).bytesize,
                               sha256: s256)
      end
      new_stats = statistical_run(data_size: size) do
        cr = hasher.cdc_chunk(data)
        ch = hasher.batch_blake3_keyed_from_ranges(key, data, cr, num_threads: DEFAULT_THREADS)
        cl = cr.map { |s, e| e - s }
        ci = ch.zip(cl)
        xh = hasher.compute_xorb_hash(ci)
        fh = hasher.compute_file_hash(xh)
        s256 = Digest::SHA256.digest(data)
        serialized = serializer.serialize_xorb_from_ranges(data, cr)
        rep = [{ xorb_hash: xh, index_start: 0, index_end: ch.length, length: cl.sum,
                 range_hash: hasher.compute_verification_hash(ch) }]
        serializer.build_shard(file_hash: fh, representation: rep, chunk_hashes: ch,
                               chunk_lengths: cl, xorb_hash: xh,
                               xorb_serialized_size: serialized.bytesize, sha256: s256)
      end
      speedup = ((new_stats[:throughput_mbps] - old_stats[:throughput_mbps]) / old_stats[:throughput_mbps] * 100).round(1)
    else
      new_stats = nil
      speedup = "N/A"
    end

    comp_rows << {
      "Size" => label,
      "OLD Avg(s)" => old_stats[:avg].round(4),
      "OLD MB/s" => old_stats[:throughput_mbps],
      "NEW Avg(s)" => new_stats ? new_stats[:avg].round(4) : "N/A",
      "NEW MB/s" => new_stats ? new_stats[:throughput_mbps] : "N/A",
      "Improve" => new_stats ? "#{speedup.positive? ? '+' : ''}#{speedup}%" : "N/A",
    }
  end
  print_stats_table(comp_rows)
end

# ── Pipeline Overhead Analysis ──

safe_bench("Pipeline Overhead Analysis") do
  size = 10_485_760  # 10 MB
  data = Random.bytes(size)

  steps = []

  # Step 1: CDC only
  warmup { hasher.cdc_chunk(data) }
  cdc_stats = statistical_run(data_size: size) { hasher.cdc_chunk(data) }
  steps << { label: "CDC only", stats: cdc_stats }

  # Step 2: CDC + Blake3 sequential
  chunk_ranges = hasher.cdc_chunk(data)
  chunks_data = chunk_ranges.map { |s, e| data.byteslice(s, e - s) }
  warmup { chunks_data.each { |cd| hasher.blake3_keyed(key, cd) } }
  blake3_seq_stats = statistical_run(data_size: size) do
    chunks_data.each { |cd| hasher.blake3_keyed(key, cd) }
  end
  steps << { label: "CDC + Blake3 seq", stats: blake3_seq_stats }

  # Step 3: CDC + Blake3 batch
  warmup { hasher.batch_blake3_keyed(key, chunks_data, num_threads: DEFAULT_THREADS) }
  blake3_batch_stats = statistical_run(data_size: size) do
    hasher.batch_blake3_keyed(key, chunks_data, num_threads: DEFAULT_THREADS)
  end
  steps << { label: "CDC + Blake3 batch", stats: blake3_batch_stats }

  # Step 4: CDC + Blake3 + Serialize OLD
  warmup do
    cr = hasher.cdc_chunk(data)
    cd = cr.map { |s, e| data.byteslice(s, e - s) }
    hasher.batch_blake3_keyed(key, cd, num_threads: DEFAULT_THREADS)
    serializer.serialize_xorb(cd)
  end
  serialize_old_stats = statistical_run(data_size: size) do
    cr = hasher.cdc_chunk(data)
    cd = cr.map { |s, e| data.byteslice(s, e - s) }
    hasher.batch_blake3_keyed(key, cd, num_threads: DEFAULT_THREADS)
    serializer.serialize_xorb(cd)
  end
  steps << { label: "CDC + Blake3 + Serialize OLD", stats: serialize_old_stats }

  # Step 5: Full NEW pipeline
  if serializer.respond_to?(:serialize_xorb_from_ranges)
    warmup do
      cr = hasher.cdc_chunk(data)
      hasher.batch_blake3_keyed_from_ranges(key, data, cr, num_threads: DEFAULT_THREADS)
      serializer.serialize_xorb_from_ranges(data, cr)
    end
    full_new_stats = statistical_run(data_size: size) do
      cr = hasher.cdc_chunk(data)
      hasher.batch_blake3_keyed_from_ranges(key, data, cr, num_threads: DEFAULT_THREADS)
      serializer.serialize_xorb_from_ranges(data, cr)
    end
    steps << { label: "Full NEW pipeline", stats: full_new_stats }
  end

  print_overhead_analysis(steps)
end

# ── Batch Upload Pipeline (multiple files) ──

safe_bench("Batch Upload Pipeline (multiple small files)") do
  batch_configs = [
    { label: "20 x 1 KB", count: 20, size: 1_024 },
    { label: "10 x 10 KB", count: 10, size: 10_240 },
    { label: "5 x 100 KB", count: 5, size: 102_400 },
  ]
  multi_rows = []
  batch_configs.each do |cfg|
    files = cfg[:count].times.map { Random.bytes(cfg[:size]) }

    warmup do
      all_chunk_metas = []
      file_metas = []
      global_chunk_idx = 0
      pending_xorb_chunks = []

      files.each do |file_data|
        chunk_ranges = hasher.cdc_chunk(file_data)
        chunk_hashes = hasher.batch_blake3_keyed_from_ranges(key, file_data, chunk_ranges, num_threads: DEFAULT_THREADS)
        chunk_lengths = chunk_ranges.map { |s, e| e - s }

        chunk_ranges.each_with_index do |(s, e), ci|
          pending_xorb_chunks << { data: file_data.byteslice(s, e - s), hash: chunk_hashes[ci], length: chunk_lengths[ci] }
          all_chunk_metas << { hash: chunk_hashes[ci], length: chunk_lengths[ci] }
          global_chunk_idx += 1
        end

        chunks_info = chunk_hashes.zip(chunk_lengths)
        xorb_hash = hasher.compute_xorb_hash(chunks_info)
        file_hash = hasher.compute_file_hash(xorb_hash)

        file_metas << {
          file_hash: file_hash, sha256: Digest::SHA256.digest(file_data),
          chunk_start: global_chunk_idx - chunk_ranges.size,
          chunk_count: chunk_ranges.size, size: file_data.bytesize,
          remote_path: "file_#{file_metas.size}.bin",
        }
      end

      serialized = serializer.serialize_xorb(pending_xorb_chunks.map { |c| c[:data] })
      chunks_info = pending_xorb_chunks.map { |c| { hash: c[:hash], length: c[:length] } }
      xorb_hash = hasher.compute_xorb_hash(chunks_info)
      uploaded_xorbs = [{ hash: xorb_hash, chunks: chunks_info, serialized_size: serialized.bytesize }]

      file_metas.each do |fm|
        fm[:representation] = serializer.build_representation(
          fm[:chunk_start], fm[:chunk_count], all_chunk_metas, uploaded_xorbs,
        )
      end
      serializer.build_multi_file_shard(file_metas, uploaded_xorbs)
    end

    total_bytes = cfg[:count] * cfg[:size]
    stats = statistical_run(data_size: total_bytes) do
      all_chunk_metas = []
      file_metas = []
      global_chunk_idx = 0
      pending_xorb_chunks = []

      files.each do |file_data|
        chunk_ranges = hasher.cdc_chunk(file_data)
        chunk_hashes = hasher.batch_blake3_keyed_from_ranges(key, file_data, chunk_ranges, num_threads: DEFAULT_THREADS)
        chunk_lengths = chunk_ranges.map { |s, e| e - s }

        chunk_ranges.each_with_index do |(s, e), ci|
          pending_xorb_chunks << { data: file_data.byteslice(s, e - s), hash: chunk_hashes[ci], length: chunk_lengths[ci] }
          all_chunk_metas << { hash: chunk_hashes[ci], length: chunk_lengths[ci] }
          global_chunk_idx += 1
        end

        chunks_info = chunk_hashes.zip(chunk_lengths)
        xorb_hash = hasher.compute_xorb_hash(chunks_info)
        file_hash = hasher.compute_file_hash(xorb_hash)

        file_metas << {
          file_hash: file_hash, sha256: Digest::SHA256.digest(file_data),
          chunk_start: global_chunk_idx - chunk_ranges.size,
          chunk_count: chunk_ranges.size, size: file_data.bytesize,
          remote_path: "file_#{file_metas.size}.bin",
        }
      end

      serialized = serializer.serialize_xorb(pending_xorb_chunks.map { |c| c[:data] })
      chunks_info = pending_xorb_chunks.map { |c| { hash: c[:hash], length: c[:length] } }
      xorb_hash = hasher.compute_xorb_hash(chunks_info)
      uploaded_xorbs = [{ hash: xorb_hash, chunks: chunks_info, serialized_size: serialized.bytesize }]

      file_metas.each do |fm|
        fm[:representation] = serializer.build_representation(
          fm[:chunk_start], fm[:chunk_count], all_chunk_metas, uploaded_xorbs,
        )
      end
      serializer.build_multi_file_shard(file_metas, uploaded_xorbs)
    end

    multi_rows << {
      "Config" => cfg[:label],
      "Iters" => stats[:iterations],
      "Min(s)" => stats[:min].round(4),
      "Max(s)" => stats[:max].round(4),
      "Avg(s)" => stats[:avg].round(4),
      "Med(s)" => stats[:median].round(4),
      "MB/s" => stats[:throughput_mbps],
    }
  end
  print_stats_table(multi_rows)
end

puts
puts "Done."
