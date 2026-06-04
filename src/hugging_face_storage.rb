# frozen_string_literal: true

require "securerandom"
require_relative "hugging_face_storage/core/version"
require_relative "hugging_face_storage/config/configuration"
require_relative "hugging_face_storage/core/errors"
require_relative "hugging_face_storage/core/cancel_token"

# Ruby client for HuggingFace Storage Buckets — file & directory management
# with Xet CAS protocol support (CDC chunking, Blake3 hashing, Xorb/Shard).
#
# @example
#   client = HuggingFaceStorage.new(
#     token: ENV["HF_TOKEN"],
#     namespace: "user",
#     bucket: "my-bucket"
#   )
#   client.files.upload("./model.bin", "models/model.bin")
#   client.directories.download("models/qwen", "/tmp/qwen")
module HuggingFaceStorage
  autoload :BatchResult, File.expand_path("hugging_face_storage/api/batch_result", __dir__)
  autoload :HttpPool, File.expand_path("hugging_face_storage/http/http_pool", __dir__)
  autoload :Retryable, File.expand_path("hugging_face_storage/core/retryable", __dir__)
  autoload :Utils, File.expand_path("hugging_face_storage/core/utils", __dir__)
  autoload :Paths, File.expand_path("hugging_face_storage/ops/paths", __dir__)
  autoload :LfsGuard, File.expand_path("hugging_face_storage/ops/lfs_guard", __dir__)
  autoload :CopyPlanBuilder, File.expand_path("hugging_face_storage/ops/copy_plan_builder", __dir__)
  autoload :BucketQuery, File.expand_path("hugging_face_storage/ops/bucket_query", __dir__)
  autoload :EntryClassifier, File.expand_path("hugging_face_storage/ops/entry_classifier", __dir__)
  autoload :ExcludeMatcher, File.expand_path("hugging_face_storage/ops/exclude_matcher", __dir__)
  autoload :TreeLoader, File.expand_path("hugging_face_storage/ops/tree_loader", __dir__)
  autoload :LocalFileCollector, File.expand_path("hugging_face_storage/ops/local_file_collector", __dir__)
  autoload :DirectoryDownloader, File.expand_path("hugging_face_storage/ops/directory_downloader", __dir__)
  autoload :DirectoryUploader, File.expand_path("hugging_face_storage/ops/directory_uploader", __dir__)
  autoload :HFLogger, File.expand_path("hugging_face_storage/logging/logger", __dir__)
  autoload :NullLogger, File.expand_path("hugging_face_storage/logging/null_logger", __dir__)
  autoload :StripIO, File.expand_path("hugging_face_storage/logging/io_helpers", __dir__)
  autoload :TeeIO, File.expand_path("hugging_face_storage/logging/io_helpers", __dir__)
  autoload :Color, File.expand_path("hugging_face_storage/logging/color", __dir__)
  autoload :Colorize, File.expand_path("hugging_face_storage/logging/colorize", __dir__)
  autoload :Authentication, File.expand_path("hugging_face_storage/core/authentication", __dir__)
  autoload :ApiClient, File.expand_path("hugging_face_storage/api/api_client", __dir__)
  autoload :AuthHeaders, File.expand_path("hugging_face_storage/api/auth_headers", __dir__)
  autoload :RequestExecutor, File.expand_path("hugging_face_storage/api/request_executor", __dir__)
  autoload :XetDataUploader, File.expand_path("hugging_face_storage/xet/xet_data_uploader", __dir__)
  autoload :XetHasher, File.expand_path("hugging_face_storage/xet/xet_hasher", __dir__)
  autoload :XetXorbBuilder, File.expand_path("hugging_face_storage/xet/xet_xorb_builder", __dir__)
  autoload :XetShardBuilder, File.expand_path("hugging_face_storage/xet/xet_shard_builder", __dir__)
  autoload :XetSerializer, File.expand_path("hugging_face_storage/xet/xet_serializer", __dir__)
  autoload :XetStreamRepresentationBuilder,
           File.expand_path("hugging_face_storage/xet/xet_stream_representation_builder", __dir__)
  autoload :XetStreamProcessor, File.expand_path("hugging_face_storage/xet/xet_stream_processor", __dir__)
  autoload :XetTokenManager, File.expand_path("hugging_face_storage/xet/xet_token_manager", __dir__)
  autoload :XetUploader, File.expand_path("hugging_face_storage/xet/xet_uploader", __dir__)
  autoload :TransportConfig, File.expand_path("hugging_face_storage/http/transport_config", __dir__)
  autoload :XetDownloader, File.expand_path("hugging_face_storage/xet/xet_downloader", __dir__)
  autoload :SameBucketCopyService, File.expand_path("hugging_face_storage/ops/same_bucket_copy_service", __dir__)
  autoload :SingleFileUploadPipeline, File.expand_path("hugging_face_storage/xet/single_file_upload_pipeline", __dir__)
  autoload :BatchFileUploadPipeline, File.expand_path("hugging_face_storage/xet/batch_file_upload_pipeline", __dir__)
  autoload :BatchShardRegistrar, File.expand_path("hugging_face_storage/xet/batch_shard_registrar", __dir__)
  autoload :SourceIterator, File.expand_path("hugging_face_storage/ops/source_iterator", __dir__)
  autoload :CrossRepoCopyService, File.expand_path("hugging_face_storage/ops/cross_repo_copy_service", __dir__)
  autoload :RepoCopyStrategy, File.expand_path("hugging_face_storage/ops/repo_copy_strategy", __dir__)
  autoload :FolderCopyStrategy, File.expand_path("hugging_face_storage/ops/folder_copy_strategy", __dir__)
  autoload :BatchPlanExecutor, File.expand_path("hugging_face_storage/ops/batch_plan_executor", __dir__)
  autoload :CasClient, File.expand_path("hugging_face_storage/xet/cas_client", __dir__)
  autoload :RepoFileCopier, File.expand_path("hugging_face_storage/ops/repo_file_copier", __dir__)
  autoload :FileInfo, File.expand_path("hugging_face_storage/ops/file_info", __dir__)
  autoload :XetLazyFile, File.expand_path("hugging_face_storage/xet/xet_lazy_file", __dir__)
  autoload :EntryInfo, File.expand_path("hugging_face_storage/ops/entry_info", __dir__)
  autoload :FileEditor, File.expand_path("hugging_face_storage/ops/file_editor", __dir__)
  autoload :FileUploadService, File.expand_path("hugging_face_storage/ops/file_upload_service", __dir__)
  autoload :FileDeleteService, File.expand_path("hugging_face_storage/ops/file_delete_service", __dir__)
  autoload :FileCopyService, File.expand_path("hugging_face_storage/ops/file_copy_service", __dir__)
  autoload :Lister, File.expand_path("hugging_face_storage/ops/lister", __dir__)
  autoload :Metadata, File.expand_path("hugging_face_storage/ops/metadata", __dir__)
  autoload :CrossCopy, File.expand_path("hugging_face_storage/ops/cross_copy", __dir__)
  autoload :FileManager, File.expand_path("hugging_face_storage/ops/file_manager", __dir__)
  autoload :DirInfo, File.expand_path("hugging_face_storage/ops/dir_info", __dir__)
  autoload :DirectoryCrudService, File.expand_path("hugging_face_storage/ops/directory_crud_service", __dir__)
  autoload :DirectoryTransferService, File.expand_path("hugging_face_storage/ops/directory_transfer_service", __dir__)
  autoload :DirectoryCopyService, File.expand_path("hugging_face_storage/ops/directory_copy_service", __dir__)
  autoload :MetadataCache, File.expand_path("hugging_face_storage/ops/metadata_cache", __dir__)
  autoload :DirectoryManager, File.expand_path("hugging_face_storage/ops/directory_manager", __dir__)
  autoload :Snapshot, File.expand_path("hugging_face_storage/ops/snapshot", __dir__)
  autoload :Client, File.expand_path("hugging_face_storage/client/client", __dir__)
  autoload :CLI, File.expand_path("hugging_face_storage/cli/cli", __dir__)
  autoload :BucketsCLI, File.expand_path("hugging_face_storage/cli/cli", __dir__)
  autoload :Instrumentation, File.expand_path("hugging_face_storage/logging/instrumentation", __dir__)
  autoload :TokenRetryable, File.expand_path("hugging_face_storage/core/token_retryable", __dir__)
  autoload :MetricsRegistry, File.expand_path("hugging_face_storage/logging/metrics_registry", __dir__)
  autoload :Notifications, File.expand_path("hugging_face_storage/logging/notifications", __dir__)
  autoload :NullMetricsRegistry, File.expand_path("hugging_face_storage/logging/null_metrics_registry", __dir__)
  autoload :NullNotifications, File.expand_path("hugging_face_storage/logging/null_notifications", __dir__)
  autoload :RedirectFollower, File.expand_path("hugging_face_storage/api/redirect_follower", __dir__)
  autoload :CLIFormatter, File.expand_path("hugging_face_storage/cli/formatter", __dir__)
  autoload :CopyPipeline, File.expand_path("hugging_face_storage/ops/copy_pipeline", __dir__)
  autoload :PaginationService, File.expand_path("hugging_face_storage/api/pagination_service", __dir__)
  autoload :PageParameterDetector, File.expand_path("hugging_face_storage/api/page_parameter_detector", __dir__)
  autoload :ParallelPageFetcher, File.expand_path("hugging_face_storage/api/parallel_page_fetcher", __dir__)
  autoload :SequentialPageFetcher, File.expand_path("hugging_face_storage/api/sequential_page_fetcher", __dir__)
  autoload :RequestLogger, File.expand_path("hugging_face_storage/api/request_logger", __dir__)
  autoload :BatchHandler, File.expand_path("hugging_face_storage/api/batch_handler", __dir__)
  autoload :FileDownloader, File.expand_path("hugging_face_storage/ops/file_downloader", __dir__)
  autoload :ResponseFields, File.expand_path("hugging_face_storage/core/response_fields", __dir__)
  autoload :ApiOperations, File.expand_path("hugging_face_storage/core/api_paths", __dir__)
  autoload :ApiPaths, File.expand_path("hugging_face_storage/core/api_paths", __dir__)
  autoload :Blake3Pool, File.expand_path("hugging_face_storage/xet/blake3_pool", __dir__)
  autoload :Blake3Binding, File.expand_path("hugging_face_storage/xet/blake3_binding", __dir__)
  autoload :Blake3Buffers, File.expand_path("hugging_face_storage/xet/blake3_binding", __dir__)
  autoload :CdcChunker, File.expand_path("hugging_face_storage/xet/cdc_chunker", __dir__)
  autoload :XorbHashTree, File.expand_path("hugging_face_storage/xet/xorb_hash_tree", __dir__)
  autoload :HTTPTransport, File.expand_path("hugging_face_storage/http/http_transport", __dir__)
  autoload :HttpErrorHandler, File.expand_path("hugging_face_storage/core/http_error_handler", __dir__)
  autoload :FileExistence, File.expand_path("hugging_face_storage/ops/file_existence", __dir__)

  def self.new(...)
    Client::Builder.new(...).build
  end

  # Create a storage client using a block-style builder.
  #
  # @yield [Builder] a Builder instance for configuration
  # @return [Client]
  def self.build
    builder = Client::Builder.new
    yield(builder)
    builder.build
  end
end
