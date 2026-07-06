# frozen_string_literal: true

module HuggingFaceStorage
  # Downloads files from HuggingFace repositories via the resolve endpoint.
  class FileDownloader
    # Initializes a new FileDownloader.
    #
    # @param api_client [ApiClient] the API client
    # @param logger [Logger, nil] the logger instance
    def initialize(api_client:, logger: nil)
      @api = api_client
      @logger = logger
    end

    # Streams a file download from a repository.
    #
    # @param repo_type [String] repository type ("model", "dataset", "space")
    # @param repo_name [String] repository identifier
    # @param path [String] file path within the repo
    # @param revision [String, nil] git revision
    # @param cancel_token [CancelToken, nil] cooperative cancellation token
    # @yield [String] yields response chunks
    # @return [void]
    def download_repo_file_streaming(repo_type, repo_name, path, revision: nil, cancel_token: nil, &block)
      url = build_repo_file_url(repo_type, repo_name, path, revision)
      @logger.debug { "Streaming download: #{url}" }
      @api.stream_with_redirect(URI.parse(url), max_redirects: 5, cancel_token: cancel_token, &block)
    end

    # Downloads a file from a repository as a byte string.
    #
    # @param repo_type [String] repository type ("model", "dataset", "space")
    # @param repo_name [String] repository identifier
    # @param path [String] file path within the repo
    # @param revision [String, nil] git revision
    # @param cancel_token [CancelToken, nil] cooperative cancellation token
    # @return [String] file contents as binary string
    def download_repo_file(repo_type, repo_name, path, revision: nil, cancel_token: nil)
      url = build_repo_file_url(repo_type, repo_name, path, revision)
      @logger.debug { "Downloading repo file: #{url}" }
      response = @api.request_with_redirect(URI.parse(url), cancel_token: cancel_token)
      response.body.b
    end

    private

    # Builds the resolve URL for downloading a file from a repository.
    #
    # @param repo_type [String] repository type ("model", "dataset", "space")
    # @param repo_name [String] repository identifier
    # @param path [String] file path within the repo
    # @param revision [String, nil] git revision
    # @return [String] the constructed download URL
    def build_repo_file_url(repo_type, repo_name, path, revision)
      prefix = repo_type == "model" ? "" : "#{repo_type}s/"
      rev_segment = revision ? "/#{revision}" : ""
      encoded_path = Paths.encode_segments(path)
      "#{@api.endpoint}/#{prefix}#{repo_name}/resolve#{rev_segment}/#{encoded_path}"
    end
  end
end
