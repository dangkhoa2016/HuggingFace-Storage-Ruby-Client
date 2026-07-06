# frozen_string_literal: true

module HuggingFaceStorage
  module Blake3PoolWorker
    # Maximum seconds to wait for a result.
    RESULT_TIMEOUT = 60

    private

    def start_worker
      buffers = Blake3Buffers.new
      Thread.new do
        loop do
          entry = dequeue_job
          break unless entry

          begin
            process_worker_request(entry, buffers)
          rescue StandardError => e
            record_worker_error(entry, e)
          end
        end
      rescue StandardError
        @mutex.synchronize { @result_available.broadcast }
      ensure
        buffers.free
      end
    end

    # Poll interval for workers to re-check pending queue (prevents lost-wakeup hangs on older Ruby).
    QUEUE_POLL_INTERVAL = 5

    def dequeue_job
      @mutex.synchronize do
        @job_available.wait(@mutex, QUEUE_POLL_INTERVAL) while @pending.empty? && !@shutdown
        return nil if @pending.empty? && @shutdown

        @pending.shift
      end
    end

    def record_worker_error(entry, error)
      @mutex.synchronize do
        @completed[entry[0]] = { index: entry[1] ? entry[1][:index] : -1, error: error }
        @result_available.broadcast
      end
    end

    def process_worker_request(request, buffers)
      id, payload = request
      hash = @hasher.blake3_keyed_with_buffers(buffers, payload[:key], payload[:data])
      @mutex.synchronize do
        @completed[id] = { index: payload[:index], value: hash }
        @result_available.signal
      end
    end

    def collect_results(job_ids, cancel_token)
      results = Array.new(job_ids.size)
      job_ids.size.times do
        completed_entry = @mutex.synchronize do
          loop do
            break if @completed.any?

            if cancel_token&.cancelled?
              @pending.clear
              @completed.clear
              raise CancelledError, "Operation cancelled"
            end

            result = @result_available.wait(@mutex, RESULT_TIMEOUT)
            next if result

            @pending.clear
            @completed.clear
            raise TimeoutError, "Blake3Pool result timeout after #{RESULT_TIMEOUT}s"
          end
          _key, value = @completed.shift
          value
        end
        completed_entry or next

        raise completed_entry[:error] if completed_entry[:error]

        results[completed_entry[:index]] = completed_entry[:value]
      end
      results
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
      @mutex = Mutex.new
      @job_available = ConditionVariable.new
      @result_available = ConditionVariable.new
      @pending = {} # : Hash[Integer, Hash[Symbol, untyped]]
      @completed = {} # : Hash[Integer, Hash[Symbol, untyped]]
      @next_id = 0
      @shutdown = false
      @workers = Array.new(size) { start_worker }
    end

    # Computes hashes for an array of data inputs in parallel.
    #
    # @param data_array [Array<String>] the data to hash
    # @param key [String] the 32-byte BLAKE3 key
    # @param cancel_token [CancelToken, nil] optional cancellation token
    # @return [Array<String>] the hashes in input order
    # @raise [CancelledError] if cancelled
    # @raise [TimeoutError] if results take too long
    def map(data_array, key, cancel_token: nil)
      return [] if data_array.empty?

      job_ids = [] # : Array[Integer]
      @mutex.synchronize do
        @completed.clear
        data_array.each_with_index do |data, i|
          id = @next_id
          @next_id += 1
          @pending[id] = { key: key, data: data, index: i }
          job_ids << id
        end
        @job_available.broadcast
      end

      cancel_proc = nil
      if cancel_token
        cancel_proc = -> { @mutex.synchronize { @result_available.broadcast } }
        cancel_token.on_cancel(&cancel_proc)
      end

      collect_results(job_ids, cancel_token)
    ensure
      cancel_token&.cancel_subscription(cancel_proc) if cancel_token && cancel_proc
    end

    # Shuts down all worker threads and waits for them to finish.
    #
    # @return [void]
    def shutdown
      @mutex.synchronize do
        @shutdown = true
        @job_available.broadcast
      end
      @workers.each do |w|
        next unless w.alive?

        5.times do
          break if w.join(2)
          w.kill
          w.wakeup
        end
        w.kill
      end
      @workers.clear
    end
  end
end
