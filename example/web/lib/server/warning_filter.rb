# frozen_string_literal: true

module Example
  module ServerWarningFilter
    def warn(message, category: nil, **kwargs)
      return if message.to_s.include?("IO::Buffer is experimental")

      super
    end
  end
end

Warning.extend Example::ServerWarningFilter
