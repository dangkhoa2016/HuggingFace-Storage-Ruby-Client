# frozen_string_literal: true

module HuggingFaceStorage
  # Shared initializer for transport-dependent services.
  #
  # When +transport+ is not provided, creates a default +HttpPool+ and
  # +Retryable+ from +@config+ and +@logger+.  Services that include this
  # module must set +@config+ and +@logger+ before calling
  # +init_transport_config!+.
  # @api private
  # :nodoc:
  module TransportConfig
    # Initialises transport infrastructure if no custom transport was given.
    #
    # Sets +@http_pool+ and +@retryable+ instance variables.
    #
    # @param transport [HTTPTransport, nil] optional pre-configured transport
    # @return [void]
    def init_transport_config!(transport)
      @transport = transport
      return unless @transport.nil?

      @http_pool = HttpPool.new(config: @config, logger: @logger)
      @retryable = Retryable.new(logger: @logger)
    end
  end
end
