# frozen_string_literal: true

module HuggingFaceStorage
  # Value object holding file metadata (path, size, xet_hash, mtime).
  class FileInfo
    # @return [String] file path
    # @return [Integer] file size in bytes
    # @return [String, nil] xet hash
    # @return [Integer, nil] modification timestamp
    attr_reader :path, :size, :xet_hash, :mtime

    # @param path [String] file path
    # @param size [Integer] file size in bytes
    # @param xet_hash [String, nil] xet hash
    # @param mtime [Integer, nil] modification time
    def initialize(path:, size:, xet_hash: nil, mtime: nil)
      @path = path
      @size = size
      @xet_hash = xet_hash
      @mtime = mtime
    end

    # Returns the basename of the path.
    #
    # @return [String] file name
    def name
      File.basename(@path)
    end

    # Returns the directory portion of the path, or nil if at root.
    #
    # @return [String, nil] directory path
    def directory
      dir = File.dirname(@path)
      dir == "." ? nil : dir
    end

    # @return [Hash] attribute hash
    def to_h
      { path: @path, size: @size, xet_hash: @xet_hash, mtime: @mtime }
    end

    # @return [String] compact inspect string
    def inspect
      "#<FileInfo path=#{@path.inspect} size=#{@size}>"
    end
  end
end
