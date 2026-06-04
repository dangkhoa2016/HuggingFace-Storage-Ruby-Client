# frozen_string_literal: true

module HuggingFaceStorage
  # Value object holding directory metadata (path, file_count, total_size, uploaded_at).
  class DirInfo
    # @return [String] the directory path
    # @return [Integer, nil] the file count
    # @return [Integer, nil] the total size in bytes
    # @return [Time, nil] the upload timestamp
    attr_reader :path, :file_count, :total_size, :uploaded_at

    # Creates a new DirInfo.
    #
    # @param path [String] the directory path
    # @param file_count [Integer, nil] number of files
    # @param total_size [Integer, nil] total size in bytes
    # @param uploaded_at [Time, nil] upload timestamp
    def initialize(path:, file_count: nil, total_size: nil, uploaded_at: nil)
      @path = path
      @file_count = file_count
      @total_size = total_size
      @uploaded_at = uploaded_at
    end

    # Returns the directory basename.
    #
    # @return [String] the directory name
    def name
      File.basename(@path)
    end

    # Returns the parent directory path, or nil if at root.
    #
    # @return [String, nil] the parent path
    def parent
      dir = File.dirname(@path)
      dir == "." ? nil : dir
    end

    # Converts to a hash.
    #
    # @return [Hash] hash representation
    def to_h
      { path: @path, file_count: @file_count, total_size: @total_size, uploaded_at: @uploaded_at }
    end

    # Returns a human-readable representation.
    #
    # @return [String] inspect string
    def inspect
      "#<DirInfo path=#{@path.inspect} files=#{@file_count} size=#{@total_size}>"
    end
  end
end
