# frozen_string_literal: true

module HuggingFaceStorage
  # String constants for JSON response field names used across the API.
  module ResponseFields
    # @return [String] JSON field name for the entry type
    TYPE     = "type"
    # @return [String] JSON field name for the file path
    PATH     = "path"
    # @return [String] JSON field name for the file size
    SIZE     = "size"
    # @return [String] JSON field name for the Xet hash
    XET_HASH = "xetHash"
    # @return [String] JSON field name for the modification time
    MTIME    = "mtime"
    # @return [String] JSON field name for LFS metadata
    LFS      = "lfs"

    # @return [String] entry type value for files
    FILE_TYPE  = "file"
    # @return [String] entry type value for directories
    DIR_TYPE   = "directory"
  end
end
