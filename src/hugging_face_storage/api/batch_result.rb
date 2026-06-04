# frozen_string_literal: true

module HuggingFaceStorage
  # Tracks succeeded/failed operations in batch API calls. Thread-safe.
  class BatchResult
    # @return [Array<String>] list of succeeded entries
    # @return [Array<Hash>] list of failed entries with :path and :error
    attr_reader :succeeded, :failed

    # Creates an empty batch result.
    def initialize
      @succeeded = []
      @failed = []
      @mutex = Mutex.new
    end

    # Records a successful operation.
    #
    # @param entry [Object] the succeeded entry
    # @return [self]
    def add_success(entry)
      @mutex.synchronize { @succeeded << entry }
      self
    end

    # Records a failed operation.
    #
    # @param path [String] the path that failed
    # @param error [StandardError] the error that occurred
    # @return [self]
    def add_failure(path, error)
      @mutex.synchronize { @failed << { path: path, error: error } }
      self
    end

    # Returns whether all operations succeeded.
    #
    # @return [Boolean] true if no failures
    def success?
      @mutex.synchronize { @failed.empty? }
    end

    # Returns the number of failed operations.
    #
    # @return [Integer] failure count
    def failure_count
      @mutex.synchronize { @failed.size }
    end

    # Returns the number of successful operations.
    #
    # @return [Integer] success count
    def success_count
      @mutex.synchronize { @succeeded.size }
    end

    # Merges another BatchResult into this one.
    #
    # @param other [BatchResult] the result to merge
    # @return [self]
    def merge!(other)
      @mutex.synchronize do
        @succeeded.concat(other.succeeded)
        @failed.concat(other.failed)
      end
      self
    end

    # Raises if any failures exist.
    #
    # @raise [PartialFailureError] if there are failures
    # @return [void]
    def raise_if_any!
      return if success?

      sample = @failed.first(5).map { |f| "#{f[:path]}: #{f[:error]}" }.join(", ")
      raise PartialFailureError.new(
        "#{@failed.size} operation(s) failed: #{sample}",
        result: self
      )
    end

    # Converts the result to a hash.
    #
    # @return [Hash] hash with :succeeded and :failed keys
    def to_h
      { succeeded: @succeeded.dup, failed: @failed.dup }
    end

    # Returns whether no operations were recorded.
    #
    # @return [Boolean] true if both lists are empty
    def empty?
      @mutex.synchronize { @succeeded.empty? && @failed.empty? }
    end
  end
end
