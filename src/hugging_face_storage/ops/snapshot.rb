# frozen_string_literal: true

require "digest"
require "json"
require "fileutils"

module HuggingFaceStorage
  # Downloads a remote directory snapshot with an optional integrity verification manifest.
  class Snapshot
    # Filename for the snapshot manifest stored alongside downloaded files.
    # @return [String]
    METADATA_FILENAME = ".huggingface_snapshot.json"

    # @param api_client [ApiClient] the API client
    # @param xet_downloader [XetDownloader] downloader for file data
    # @param file_manager [FileManager] file listing interface
    # @param directory_manager [DirectoryManager] directory operations
    # @param bucket_id [String] bucket identifier
    # @param logger [Logger, nil] logger instance
    # @param config [Configuration, nil] configuration
    def initialize(api_client:, xet_downloader:, file_manager:, directory_manager:, bucket_id:, logger: nil,
                   config: nil)
      @api = api_client
      @xet_downloader = xet_downloader
      @files = file_manager
      @dirs = directory_manager
      @bucket_id = bucket_id
      @logger = logger || NullLogger.new
      @config = config || Configuration.default
    end

    # Downloads +remote_path+ to +local_dir+ with an optional manifest and verification.
    #
    # @param remote_path [String] remote directory path
    # @param local_dir [String] local destination directory
    # @param verify [Boolean] verify sizes in manifest (default false)
    # @param verify_content [Boolean] also verify SHA-256 in manifest (default false)
    # @return [Hash] keys :directory, :local_path, :files_downloaded, :manifest_path, :verified
    def download(remote_path, local_dir, verify: false, verify_content: false)
      normalized = Paths.normalize(remote_path)
      @logger.info("Snapshot download: #{normalized} -> #{local_dir}")

      files = @files.list(prefix: normalized, recursive: true)
      raise NotFoundError, "No files found for snapshot: #{remote_path}" if files.empty?

      download_with_manifest(files, normalized, local_dir, verify, verify_content)
    end

    # Verifies downloaded files against the manifest (sizes and optional SHA-256).
    #
    # @param local_dir [String] local directory containing downloaded files
    # @param manifest [Hash] the snapshot manifest
    # @param verify_content [Boolean] also verify SHA-256 checksums
    # @return [Array<Hash>] list of mismatches (path and reason)
    def verify_files(local_dir, manifest, verify_content: false)
      source_prefix = manifest["source_prefix"]
      files_list = manifest["files"]

      mismatches = [] # : Array[Hash[Symbol, untyped]]
      needs_sha256 = check_file_sizes(files_list, source_prefix, local_dir, mismatches, verify_content)

      verify_sha256_in_parallel(needs_sha256, mismatches) if needs_sha256.any?

      mismatches
    end

    # Loads a snapshot manifest from +local_dir+.
    #
    # @param local_dir [String] directory containing the manifest file
    # @return [Hash, nil] parsed manifest or nil if not found
    def self.load_manifest(local_dir)
      path = File.join(local_dir, METADATA_FILENAME)
      return nil unless File.exist?(path)

      JSON.parse(File.read(path))
    end

    module SnapshotHelpers
      private

      def check_file_sizes(files_list, source_prefix, local_dir, mismatches, verify_content)
        needs_sha256 = []

        files_list.each do |entry|
          path = entry[ResponseFields::PATH]
          relative = source_prefix ? path.sub(%r{^#{Regexp.escape(source_prefix)}/?}, "") : path
          local_path = File.join(local_dir, relative)
          unless File.exist?(local_path)
            mismatches << { path: path, reason: "missing" }
            next
          end
          actual_size = File.size(local_path)
          expected_size = entry[ResponseFields::SIZE]
          if actual_size != expected_size
            mismatches << { path: path, reason: "size mismatch (expected #{expected_size}, got #{actual_size})" }
            next
          end
          if verify_content
            expected_sha256 = entry["sha256"]
            needs_sha256 << { path: path, local_path: local_path, sha256: expected_sha256 } if expected_sha256
          end
        end

        needs_sha256
      end

      def verify_sha256_in_parallel(needs_sha256, mismatches)
        mutex = Mutex.new
        queue = Queue.new
        needs_sha256.each { |item| queue << item }
        num_workers = [@config.parallel_verify || 8, needs_sha256.size].min

        workers = Array.new(num_workers) do
          Thread.new do
            loop do
              item = queue.pop(true)
            rescue ThreadError
              break
            else
              actual_sha256 = Digest::SHA256.file(item[:local_path]).hexdigest
              if actual_sha256 != item[:sha256]
                mutex.synchronize do
                  mismatches << { path: item[:path], reason: "sha256 mismatch" }
                end
              end
            end
          end
        end
        workers.each(&:join)
      end

      def build_manifest(files, source_prefix, local_dir, compute_sha256: false)
        {
          "snapshot_at" => Time.now.utc.iso8601,
          "bucket_id" => @bucket_id,
          "source_prefix" => source_prefix,
          "files" => files.map do |f|
            entry = { ResponseFields::PATH => f.path, ResponseFields::SIZE => f.size, "xet_hash" => f.xet_hash, "mtime" => f.mtime }
            if compute_sha256
              relative = source_prefix ? f.path.sub(%r{^#{Regexp.escape(source_prefix)}/?}, "") : f.path
              local_path = File.join(local_dir, relative)
              entry["sha256"] = Digest::SHA256.file(local_path).hexdigest if File.exist?(local_path)
            end
            entry
          end,
        }
      end

      def download_with_manifest(files, normalized, local_dir, verify, verify_content)
        downloader = DirectoryDownloader.new(
          api_client: @api, xet_downloader: @xet_downloader, bucket_id: @bucket_id, logger: @logger, config: @config
        )
        downloader.download(files, normalized, local_dir, parallel: @config.parallel_downloads)

        manifest = build_manifest(files, normalized, local_dir, compute_sha256: verify_content)
        manifest_path = File.join(local_dir, METADATA_FILENAME)
        File.write(manifest_path, JSON.pretty_generate(manifest))

        if verify || verify_content
          mismatches = verify_files(local_dir, manifest, verify_content: verify_content)
          unless mismatches.empty?
            raise Error, "Snapshot verification failed for #{mismatches.size} file(s): " \
                         "#{mismatches.first(5).map { |m| m[:path] }.join(', ')}"
          end
        end

        @logger.info("Snapshot complete: #{files.size} file(s), manifest at #{manifest_path}")
        {
          directory: normalized,
          local_path: local_dir,
          files_downloaded: files.size,
          manifest_path: manifest_path,
          verified: verify || verify_content,
        }
      end
    end

    include SnapshotHelpers
  end
end
