# frozen_string_literal: true

module HuggingFaceStorage
  class Client
    # Constructs all service objects required by Client during the build phase.
    class ServiceFactory
      module BuildHelpers
        def build_file_services(xet_uploader, xet_downloader, api, same_bucket_copy, cross_repo_copy, copy_pipeline)
          file_upload = FileUploadService.new(xet_uploader: xet_uploader,
                                              bucket_id: @bucket_id,
                                              logger: @logger,
                                              metrics_registry: @metrics_registry,
                                              notifications: @notifications)
          file_delete = FileDeleteService.new(api_client: api,
                                              bucket_id: @bucket_id,
                                              config: @config, logger: @logger,
                                              metrics_registry: @metrics_registry,
                                              notifications: @notifications)
          file_copy   = FileCopyService.new(same_bucket: same_bucket_copy,
                                            cross_repo: cross_repo_copy,
                                            copy_pipeline: copy_pipeline,
                                            logger: @logger, config: @config,
                                            metrics_registry: @metrics_registry,
                                            notifications: @notifications)

          FileManager.new(upload_service: file_upload,
                          delete_service: file_delete,
                          copy_service: file_copy,
                          api_client: api,
                          xet_uploader: xet_uploader,
                          xet_downloader: xet_downloader,
                          bucket_id: @bucket_id, config: @config,
                          logger: @logger)
        end

        def build_directory_services(api, xet_uploader, xet_downloader, files, copy_pipeline, source_iterator)
          dir_crud = DirectoryCrudService.new(api_client: api,
                                              xet_uploader: xet_uploader,
                                              file_manager: files,
                                              bucket_id: @bucket_id,
                                              config: @config, logger: @logger,
                                              metrics_registry: @metrics_registry,
                                              notifications: @notifications)
          dir_transfer = DirectoryTransferService.new(
            api_client: api, xet_uploader: xet_uploader,
            xet_downloader: xet_downloader, file_manager: files,
            bucket_id: @bucket_id, config: @config, logger: @logger,
            metrics_registry: @metrics_registry, notifications: @notifications
          )
          dir_copy = build_directory_copy_service(api, files, copy_pipeline, source_iterator)

          DirectoryManager.new(
            crud_service: dir_crud, transfer_service: dir_transfer,
            copy_service: dir_copy, api_client: api,
            xet_uploader: xet_uploader, xet_downloader: xet_downloader,
            file_manager: files, bucket_id: @bucket_id, config: @config,
            logger: @logger
          )
        end

        def build_directory_copy_service(api, files, copy_pipeline, source_iterator)
          same_bucket_dir_copy = SameBucketCopyService.new(
            api_client: api, bucket_id: @bucket_id,
            config: @config, logger: @logger,
            file_manager: files,
            copy_pipeline: copy_pipeline,
            metrics_registry: @metrics_registry, notifications: @notifications
          )
          dir_cross_repo_copy = CrossRepoCopyService.new(
            api_client: api, file_manager: files,
            copy_pipeline: copy_pipeline, bucket_id: @bucket_id,
            source_iterator: source_iterator, logger: @logger,
            metrics_registry: @metrics_registry, notifications: @notifications
          )
          DirectoryCopyService.new(
            same_bucket_copy: same_bucket_dir_copy,
            cross_repo_copy: dir_cross_repo_copy,
            copy_pipeline: copy_pipeline, config: @config, logger: @logger,
            metrics_registry: @metrics_registry, notifications: @notifications
          )
        end
      end

      include BuildHelpers

      def initialize(config:, logger:, token:, bucket_id:, metrics_registry: nil, notifications: nil)
        @config = config
        @logger = logger
        @metrics_registry = metrics_registry || NullMetricsRegistry.instance
        @notifications = notifications || NullNotifications.instance
        @token = token
        @bucket_id = bucket_id
      end

      def build_auth_and_transport
        auth = Authentication.new(token: @token)
        transport = HTTPTransport.new(config: @config, logger: @logger)
        file_existence = FileExistence.new(transport: transport, logger: @logger)
        api = ApiClient.new(auth: auth, config: @config, logger: @logger,
                            transport: transport,
                            file_existence: file_existence)
        [auth, api]
      end

      def build_xet_services(api)
        hasher     = XetHasher.new
        serializer = XetSerializer.new(hasher)
        token_mgr  = XetTokenManager.new(api_client: api, logger: @logger,
                                         config: @config)
        endpoint   = @config.base_url.dup
        xet_uploader = XetUploader.new(hasher: hasher, serializer: serializer,
                                       token_manager: token_mgr,
                                       api_client: api, endpoint: endpoint,
                                       logger: @logger, config: @config,
                                       metrics_registry: @metrics_registry,
                                       notifications: @notifications)
        xet_downloader = XetDownloader.new(api_client: api,
                                           token_manager: token_mgr,
                                           endpoint: endpoint,
                                           logger: @logger, config: @config,
                                           metrics_registry: @metrics_registry,
                                           notifications: @notifications)
        [xet_uploader, xet_downloader]
      end

      def build_copy_services(api, xet_uploader)
        same_bucket_copy = SameBucketCopyService.new(api_client: api,
                                                     bucket_id: @bucket_id,
                                                     config: @config,
                                                     logger: @logger,
                                                     metrics_registry: @metrics_registry,
                                                     notifications: @notifications)
        copy_pipeline = CopyPipeline.new(api_client: api,
                                         xet_uploader: xet_uploader,
                                         bucket_id: @bucket_id,
                                         config: @config, logger: @logger,
                                         metrics_registry: @metrics_registry,
                                         notifications: @notifications)
        source_iterator = SourceIterator.new(api: api, bucket_id: @bucket_id,
                                             logger: @logger,
                                             debug_mode: @config.debug_mode)
        cross_repo_copy = CrossRepoCopyService.new(
          api_client: api, file_manager: nil,
          copy_pipeline: copy_pipeline, bucket_id: @bucket_id,
          source_iterator: source_iterator, logger: @logger,
          metrics_registry: @metrics_registry, notifications: @notifications
        )
        [same_bucket_copy, copy_pipeline, cross_repo_copy, source_iterator]
      end
    end
  end
end
