# frozen_string_literal: true

module HuggingFaceStorage
  # Classifies file entries into Xet copy operations, pending downloads, or LFS offenders.
  # @api private
  # :nodoc:
  module EntryClassifier
    module_function

    # Classifies entries into copy ops, pending downloads, and LFS offenders.
    #
    # @param entries [Array<Hash>] the file entries to classify
    # @param source_type [String] source type ("model", "dataset", or "bucket")
    # @param source_repo [String] source repository name
    # @param revision [String, nil] revision (nil for buckets)
    # @param destination_mapper [Proc] maps an entry to its destination path
    # @param debug_mode [Boolean] enable debug backtraces
    # @param path_infos [Array<Hash>, nil] path metadata from the API
    # @return [Hash] with :copy_ops, :lfs_offenders, :pending_downloads
    # @raise [NotFoundError] if a source file is not found
    # @raise [Error] if source path is a directory
    def classify(entries, source_type:, source_repo:, revision:, destination_mapper:, debug_mode: false,
                 path_infos: nil)
      build_entry_mapping(entries, source_type, source_repo, revision, destination_mapper, debug_mode, path_infos)
    end

    # Builds copy ops, LFS offenders, and pending downloads from source entries.
    #
    # @param entries [Array<Hash>] the file entries to classify
    # @param source_type [String] source type
    # @param source_repo [String] source repository
    # @param revision [String, nil] revision
    # @param destination_mapper [Proc] maps an entry to its destination path
    # @param debug_mode [Boolean] enable debug backtraces
    # @param path_infos [Array<Hash>, nil] path metadata from the API
    # @return [Hash] with :copy_ops, :lfs_offenders, :pending_downloads
    def build_entry_mapping(entries, source_type, source_repo, revision, destination_mapper, debug_mode, path_infos)
      lookup = build_path_lookup(path_infos)

      copy_ops = []
      lfs_offenders = []
      pending_downloads = []

      entries.each do |entry|
        src_path = resolve_source_path(entry)
        info = lookup[src_path]
        handle_missing_entry(info, src_path, source_type, source_repo, revision, debug_mode, path_infos)

        remote_path = build_remote_path(entry, destination_mapper, nil)
        build_classified_entry(entry, remote_path, info, source_type, source_repo, revision,
                               copy_ops, lfs_offenders, pending_downloads)
      end

      { copy_ops: copy_ops, lfs_offenders: lfs_offenders, pending_downloads: pending_downloads }
    end

    # Builds a lookup hash from path info entries.
    def build_path_lookup(path_infos)
      file_entries = (path_infos || []).select do |e|
        e[ResponseFields::TYPE] == ResponseFields::FILE_TYPE
      end
      file_entries.to_h { |e| [e[ResponseFields::PATH], e] }
    end

    # Raises NotFoundError if +info+ is nil for the given source path.
    def handle_missing_entry(info, src_path, source_type, source_repo, revision, debug_mode, path_infos)
      return if info

      if path_infos&.any? { |e| e[ResponseFields::TYPE] == ResponseFields::DIR_TYPE && e[ResponseFields::PATH] == src_path }
        raise Error,
              "Source path '#{src_path}' in #{source_type}s/#{source_repo} is a folder; " \
              "use DirectoryManager#copy_from_repo instead."
      end
      ne = NotFoundError.new(
        "Source file '#{src_path}' not found in #{source_type} '#{source_repo}' " \
        "(revision: #{revision || 'latest'})."
      )
      ne.set_backtrace([]) unless debug_mode
      raise ne, cause: nil
    end

    # Builds the remote destination path for an entry via the mapper.
    #
    # @param entry [Hash, #[]] the file entry
    # @param destination_mapper [Proc] mapper callable
    # @param _source_base [String, nil] ignored source base
    # @return [String] destination path
    def build_remote_path(entry, destination_mapper, _source_base)
      destination_mapper.call(entry)
    end

    # Appends an entry to the appropriate list based on its xet_hash/LFS status.
    #
    # @param entry [Hash, #[]] the file entry
    # @param remote_path [String] destination path
    # @param info [Hash] entry metadata from the API
    # @param source_type [String] source type
    # @param source_repo [String] source repository
    # @param revision [String, nil] revision
    # @param copy_ops [Array<Hash>] accumulator for Xet copy operations
    # @param lfs_offenders [Array<Hash>] accumulator for LFS offenders
    # @param pending_downloads [Array<Hash>] accumulator for pending downloads
    # @return [void]
    def build_classified_entry(entry, remote_path, info, source_type, source_repo, revision,
                               copy_ops, lfs_offenders, pending_downloads)
      src_path = resolve_source_path(entry)
      xet_hash = info[ResponseFields::XET_HASH]
      lfs = info[ResponseFields::LFS]

      if xet_hash
        copy_ops << build_copy_op(remote_path, xet_hash, source_type, source_repo)
      elsif lfs
        lfs_offenders << { path: src_path, size: lfs[ResponseFields::SIZE] || info[ResponseFields::SIZE] }
      else
        pending_downloads << {
          source_type: source_type,
          source_repo: source_repo,
          source_path: src_path,
          destination: remote_path,
          size: info[ResponseFields::SIZE],
          revision: revision,
        }
      end
    end

    # Builds a copy operation hash for the batch API.
    #
    # @param path [String] the destination path
    # @param xet_hash [String] the Xet hash
    # @param source_type [String] source type
    # @param source_repo [String] source repository
    # @return [Hash] the copy operation
    def build_copy_op(path, xet_hash, source_type, source_repo)
      {
        type: ApiOperations::COPY_FILE,
        path: path,
        xetHash: xet_hash,
        sourceRepoType: source_type,
        sourceRepoId: source_repo,
      }
    end

    # Extracts the source path from an entry hash.
    #
    # @param entry [Hash, #[]] the entry (hash or object)
    # @return [String] the source path
    def resolve_source_path(entry)
      return entry[:source_path] if entry.is_a?(Hash) && entry.key?(:source_path)

      entry[ResponseFields::PATH]
    end
  end
end
