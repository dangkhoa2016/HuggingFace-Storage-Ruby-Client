# frozen_string_literal: true

module HuggingFaceStorage
  module Blake3PoolWorker
    RESULT_TIMEOUT = 60

    private

    def start_worker
      buffers = Blake3Buffers.new
      Thread.new do
        loop do
          entry = @job_queue.pop
          break if entry == :shutdown

          _, payload = entry
          begin
            # Support both copied data and zero-copy buffer references
            hash = if payload[:source]
                     @hasher.blake3_keyed_from_buffer(
                       buffers, payload[:key], payload[:source],
                       payload[:offset], payload[:length]
                     )
                   else
                     @hasher.blake3_keyed_with_buffers(buffers, payload[:key], payload[:data])
                   end
            @result_queue.push({ index: payload[:index], value: hash })
          rescue StandardError => e
            @result_queue.push({ index: payload[:index], error: e })
          end
        end
      rescue StandardError
        nil
      ensure
        buffers.free
      end
    end

    # Waits for the next completed result from the result queue.
    #
    # Uses a non-blocking Queue#pop with a minimal sleep fallback. The
    # common case (queue has data) returns instantly. The sleep(0.001)
    # only triggers when the queue is temporarily empty — typically between
    # batches or during worker startup. This replaces the previous
    # sleep(0.01) polling, reducing worst-case per-result latency from
    # 10ms to 1ms.
    #
    # @param cancel_token [CancelToken, nil] optional cancellation token
    # @return [Hash] the result hash with :index and :value keys
    # @raise [CancelledError] if the cancel token is already cancelled
    # @raise [TimeoutError] if no result arrives within RESULT_TIMEOUT seconds
    def wait_for_result(cancel_token)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + RESULT_TIMEOUT

      loop do
        if cancel_token&.cancelled?
          clear_queues!
          raise CancelledError, "Operation cancelled"
        end

        remaining = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
        if remaining <= 0
          clear_queues!
          raise TimeoutError, "Blake3Pool result timeout after #{RESULT_TIMEOUT}s"
        end

        # Non-blocking pop: returns immediately if data is available.
        # This is the fast path — workers are fast, queue is almost always non-empty.
        begin
          return @result_queue.pop(true)
        rescue ThreadError
          # Queue temporarily empty. Yield briefly to let workers produce results.
          # 0.001s (1ms) is the minimum meaningful sleep — far less than the
          # previous 0.01s (10ms) while still avoiding CPU spin.
          sleep([remaining, 0.001].min)
        end
      end
    end

    def collect_results(job_ids, cancel_token)
      results = Array.new(job_ids.size)
      job_ids.size.times do
        completed_entry = wait_for_result(cancel_token)
        raise completed_entry[:error] if completed_entry[:error]

        results[completed_entry[:index]] = completed_entry[:value]
      end
      results
    end

    def clear_queues!
      @job_queue.clear
      @result_queue.clear
    end
  end

  # Thread pool for parallel BLAKE3 hashing operations.
  # @api private
  # :nodoc:
  class Blake3Pool
    include Blake3PoolWorker

    # @return [Integer] the number of worker threads
    attr_reader :size

    # Creates a pool with the given hasher and thread count.
    #
    # @param hasher [#blake3_keyed_with_buffers] the hasher instance
    # @param size [Integer] number of worker threads
    def initialize(hasher, size)
      @hasher = hasher
      @size = size
      @job_queue = Thread::Queue.new
      @result_queue = Thread::Queue.new
      @workers = Array.new(size) { start_worker }
    end

    # Computes hashes for an array of data inputs in parallel.
    #
    # Dispatches all jobs to the worker queue, then collects results in
    # input order. Uses batch dispatch to minimize queue lock contention:
    # all jobs are enqueued before any results are collected, allowing
    # workers to begin processing immediately.
    #
    # @param data_array [Array<String>] the data to hash
    # @param key [String] the 32-byte BLAKE3 key
    # @param cancel_token [CancelToken, nil] optional cancellation token
    # @return [Array<String>] the hashes in input order
    # @raise [CancelledError] if cancelled
    # @raise [TimeoutError] if results take too long
    def map(data_array, key, cancel_token: nil)
      return [] if data_array.empty?

      # Batch dispatch: enqueue all jobs upfront. Workers begin processing
      # immediately while we collect results — no idle time between dispatch
      # and collection.
      data_array.each_with_index do |data, i|
        @job_queue.push([i, { key: key, data: data, index: i }])
      end

      cancel_proc = nil
      if cancel_token
        cancel_proc = -> {}
        cancel_token.on_cancel(&cancel_proc)
      end

      collect_results((0...data_array.size).to_a, cancel_token)
    ensure
      cancel_token&.cancel_subscription(cancel_proc) if cancel_token && cancel_proc
    end

    # Computes hashes for chunks from a single source buffer in parallel.
    # Zero-copy: workers hash directly from the source buffer using offsets.
    #
    # @param key [String] the 32-byte BLAKE3 key
    # @param source [String] the source data buffer
    # @param ranges [Array<Array(Integer, Integer)>] array of [start, end) ranges
    # @param cancel_token [CancelToken, nil] optional cancellation token
    # @return [Array<String>] the hashes in input order
    # @raise [CancelledError] if cancelled
    # @raise [TimeoutError] if results take too long
    def map_from_buffer(key, source, ranges, cancel_token: nil)
      return [] if ranges.empty?

      # Batch dispatch with zero-copy buffer references
      ranges.each_with_index do |range, i|
        start_pos = range[0]
        end_pos = range[1]
        @job_queue.push([i, {
          key: key,
          source: source,
          offset: start_pos,
          length: end_pos - start_pos,
          index: i,
        }])
      end

      cancel_proc = nil
      if cancel_token
        cancel_proc = -> {}
        cancel_token.on_cancel(&cancel_proc)
      end

      collect_results((0...ranges.size).to_a, cancel_token)
    ensure
      cancel_token&.cancel_subscription(cancel_proc) if cancel_token && cancel_proc
    end

    # Shuts down all worker threads and waits for them to finish.
    #
    # @return [void]
    def shutdown
      return if @shutdown

      @shutdown = true
      @size.times do
        @job_queue.push(:shutdown)
      rescue StandardError
        nil
      end
      @workers.each do |w|
        w.join(5) || w.kill
      end
      @workers.clear
      begin
        @job_queue.close
      rescue StandardError
        nil
      end
      begin
        @result_queue.close
      rescue StandardError
        nil
      end
    end
  end
end
