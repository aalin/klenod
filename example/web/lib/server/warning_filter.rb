# frozen_string_literal: true

module Example
  module Server
    module ServerWarningFilter
      def warn(message, category: nil, **kwargs)
        return if message.to_s.include?("IO::Buffer is experimental")

        super
      end
    end
  end
end

Warning.extend Example::Server::ServerWarningFilter
