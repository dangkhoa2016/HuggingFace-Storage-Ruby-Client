# frozen_string_literal: true

module HuggingFaceStorage
  # Value object representing a bucket entry (file or directory).
  class EntryInfo
    # @return [String] entry type ("file" or "directory")
    # @return [String] entry path
    # @return [Integer, nil] file size in bytes (nil for directories)
    # @return [String, nil] xet hash (files only)
    # @return [Time, nil] modification time (files) or upload time (directories)
    attr_reader :type, :path, :size, :xet_hash, :mtime

    # @param type [String] "file" or "directory"
    # @param path [String] entry path
    # @param size [Integer, nil] file size in bytes
    # @param xet_hash [String, nil] xet hash
    # @param mtime [Time, nil] modification/upload time
    def initialize(type:, path:, size: nil, xet_hash: nil, mtime: nil)
      @type = type
      @path = path
      @size = size
      @xet_hash = xet_hash
      @mtime = mtime
    end

    # Returns true if this is a directory entry.
    def directory?
      @type == ResponseFields::DIR_TYPE
    end

    # Returns true if this is a file entry.
    def file?
      @type == ResponseFields::FILE_TYPE
    end

    # Returns the basename of the path.
    #
    # @return [String] entry name
    def name
      File.basename(@path)
    end

    # Returns the parent directory path, or nil if at root.
    #
    # @return [String, nil] parent path
    def parent
      dir = File.dirname(@path)
      dir == "." ? nil : dir
    end

    # @return [Hash] attribute hash
    def to_h
      { type: @type, path: @path, size: @size, xet_hash: @xet_hash, mtime: @mtime }
    end

    # @return [String] compact inspect string
    def inspect
      "#<EntryInfo type=#{@type.inspect} path=#{@path.inspect} size=#{@size}>"
    end
  end
end
