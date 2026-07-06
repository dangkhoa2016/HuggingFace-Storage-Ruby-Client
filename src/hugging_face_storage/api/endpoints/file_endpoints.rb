# frozen_string_literal: true

module HuggingFaceStorage
  # @api private
  # :nodoc:
  module FileEndpoints
    # Checks whether a file exists in a bucket.
    #
    # @param bucket_id [String] the bucket identifier
    # @param path [String] the file path
    # @return [Boolean] true if the file exists
    def file_exists?(bucket_id, path)
      @file_existence.file_exists?(bucket_id, path)
    end

    # Lists files in a repository tree.
    #
    # @param repo_type [String] repository type (e.g. "model", "dataset")
    # @param repo_name [String] repository name
    # @param path [String, nil] optional sub-path
    # @param revision [String, nil] optional revision (branch, tag, or commit)
    # @param recursive [Boolean] list recursively (default true)
    # @return [Array<Hash>] list of file/directory entries
    def list_repo_files(repo_type, repo_name, path: nil, revision: nil, recursive: true)
      @logger.debug { "Listing repo files: #{repo_type}/#{repo_name} path=#{path} revision=#{revision}" }
      url = ApiPaths.repo_tree_path(repo_type, repo_name)
      url += "/#{revision}" if revision
      url += "/#{path}" if path
      get_paginated(url, params: { recursive: recursive.to_s }) # steep:ignore
    end

    # Streams content from a URI, following HTTP redirects.
    #
    # @param uri [URI, String] the request URI
    # @param max_redirects [Integer] maximum redirects to follow (default 5)
    # @param cancel_token [CancelToken, nil] cooperative cancellation token
    # @yield [String] yields response body chunks
    # @return [void]
    def stream_with_redirect(uri, max_redirects: 5, cancel_token: nil, &block)
      redirect_follower.follow_redirects(uri,
                                         max_redirects: max_redirects,
                                         cancel_token: cancel_token,
                                         streaming: true, &block)
    end

    # Makes a request with redirect following.
    #
    # @param uri [URI, String] the request URI
    # @param max_redirects [Integer] maximum redirects to follow (default 5)
    # @param cancel_token [CancelToken, nil] cooperative cancellation token
    # @param streaming [Boolean] whether to stream the response
    # @yield [String] yields response body chunks when streaming
    # @return [Net::HTTPResponse, nil] the final response
    def request_with_redirect(uri, max_redirects: 5, cancel_token: nil, streaming: false, &block)
      redirect_follower.follow_redirects(uri,
                                         max_redirects: max_redirects,
                                         cancel_token: cancel_token,
                                         streaming: streaming, &block)
    end

    # Posts NDJSON operations to the batch endpoint.
    #
    # @param path [String] API path
    # @param operations [Array<Hash>] batch operations
    # @param cancel_token [CancelToken, nil] cooperative cancellation token
    # @return [Array, nil] parsed response or nil
    def post_ndjson(path, operations, cancel_token: nil)
      @batch_handler.post_ndjson(path, operations, cancel_token: cancel_token)
    end

    # Sends a batch of operations to the bucket batch endpoint.
    #
    # @param bucket_id [String] the bucket identifier
    # @param operations [Array<Hash>] batch operations
    # @param cancel_token [CancelToken, nil] cooperative cancellation token
    # @param raise_on_partial_failure [Boolean] raise if any operation fails (default true)
    # @return [BatchResult] the batch result
    def batch(bucket_id, operations, cancel_token: nil, raise_on_partial_failure: true)
      @batch_handler.batch(bucket_id, operations, cancel_token: cancel_token,
                                                  raise_on_partial_failure: raise_on_partial_failure)
    end

    # Downloads a file from a repository.
    #
    # @param repo_type [String] repository type (e.g. "model", "dataset")
    # @param repo_name [String] repository name
    # @param path [String] file path
    # @param revision [String, nil] optional revision
    # @param cancel_token [CancelToken, nil] cooperative cancellation token
    # @return [String] binary file data
    def download_repo_file(repo_type, repo_name, path, revision: nil, cancel_token: nil)
      @file_downloader.download_repo_file(repo_type, repo_name, path, revision: revision, cancel_token: cancel_token)
    end

    # Downloads a file from a repository via streaming.
    #
    # @param repo_type [String] repository type (e.g. "model", "dataset")
    # @param repo_name [String] repository name
    # @param path [String] file path
    # @param revision [String, nil] optional revision
    # @param cancel_token [CancelToken, nil] cooperative cancellation token
    # @yield [String] yields data chunks
    # @return [void]
    def download_repo_file_streaming(repo_type, repo_name, path, revision: nil, cancel_token: nil, &block)
      @file_downloader.download_repo_file_streaming(repo_type, repo_name, path,
                                                    revision: revision, cancel_token: cancel_token, &block)
    end

    private

    # Lazily initializes and returns the redirect follower.
    #
    # @return [RedirectFollower] the redirect-following helper
    def redirect_follower
      @redirect_follower_mutex.synchronize do
        @redirect_follower ||= @transport.build_redirect_follower(header_applier: @auth_headers_builder.method(:apply))
      end
    end
  end
end
