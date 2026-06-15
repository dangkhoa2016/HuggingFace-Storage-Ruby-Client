# frozen_string_literal: true

$LOAD_PATH.unshift(File.expand_path("../src", __dir__))
require_relative "../src/hugging_face_storage"
require "benchmark"
require "digest/sha2"

module BenchmarkHelper
  # ── Constants ──

  DEFAULT_ITERATIONS = 20
  WARMUP_COUNT = 5
  DEFAULT_THREADS = 4
  SIZES = {
    "1 KB" => 1_024,
    "10 KB" => 10_240,
    "100 KB" => 102_400,
    "1 MB" => 1_048_576,
    "10 MB" => 10_485_760,
  }.freeze

  # ── Formatting ──

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

  def format_comparison_table(rows)
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

  # ── System info ──

  def print_header(title)
    puts "=" * 70
    puts title
    puts "  Ruby: #{RUBY_VERSION} (#{RUBY_PLATFORM})"
    puts "  Time: #{Time.now.strftime('%Y-%m-%d %H:%M:%S %Z')}"
    if native_gearhash_available?
      puts "  Native Gearhash: YES (#{File.size(so_path)} bytes)"
    else
      puts "  Native Gearhash: NO (Ruby fallback)"
    end
    puts "=" * 70
  end

  def native_gearhash_available?
    defined?(HuggingFaceStorage::Gearhash) &&
      HuggingFaceStorage::Gearhash.respond_to?(:cdc_chunk)
  end

  # ── Safe benchmark wrapper ──
  # Runs a benchmark section with error isolation.
  # If the section crashes, prints the error and continues.

  def safe_bench(section_name)
    print "\n## #{section_name}\n"
    start_time = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    yield
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - start_time
    puts "  (completed in #{elapsed.round(2)}s)"
  rescue StandardError => e
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - start_time
    puts "  ERROR after #{elapsed.round(2)}s: #{e.class}: #{e.message}"
    puts "  #{e.backtrace.first(3).join("\n  ")}" if e.backtrace
    nil
  end

  # ── Warmup ──
  # Runs a block `count` times to warm JIT and caches.

  def warmup(count: WARMUP_COUNT, &block)
    count.times(&block)
  end

  # ── Statistical benchmark runner ──
  # Runs block N times, returns stats hash with min/max/avg/median/p95.

  def statistical_run(data_size:, iterations: DEFAULT_ITERATIONS, &block)
    times = []
    iterations.times do
      t = Benchmark.measure { yield }
      times << t.real
    end
    sorted = times.sort
    {
      min: sorted.first,
      max: sorted.last,
      avg: sorted.sum / sorted.size,
      median: sorted[sorted.size / 2],
      p95: sorted[(sorted.size * 0.95).to_i],
      iterations: iterations,
      throughput_mbps: (data_size.to_f / sorted.sum * sorted.size / 1_048_576).round(1),
    }
  end

  # ── Print stats table ──
  # Prints a table with statistical columns for multiple sizes.

  def print_stats_table(stats_rows)
    format_table(stats_rows)
  end

  # ── Print breakdown table ──
  # Prints a comparison table for pipeline breakdown.

  def print_breakdown_table(breakdown_rows)
    format_comparison_table(breakdown_rows)
  end

  # ── Pipeline overhead analysis ──
  # Measures individual pipeline steps and calculates total overhead.

  def measure_pipeline_step(data_size:, label:, &block)
    stats = statistical_run(data_size: data_size, &block)
    { label: label, stats: stats }
  end

  def print_overhead_analysis(steps)
    puts "\n  Pipeline Step Analysis:"
    puts "  #{'-' * 60}"
    steps.each do |step|
      stats = step[:stats]
      puts "  #{step[:label].ljust(25)} #{stats[:throughput_mbps].to_s.rjust(8)} MB/s  (avg: #{stats[:avg].round(4)}s)"
    end
    puts "  #{'-' * 60}"

    return unless steps.size >= 2

    overhead = steps.last[:stats][:avg] / steps.first[:stats][:avg]
    puts "  Total overhead: #{overhead.round(1)}x"
  end

  private

  def so_path
    File.expand_path("../src/hugging_face_storage/gearhash.so", __dir__)
  end
end
