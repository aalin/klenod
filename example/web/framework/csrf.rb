# frozen_string_literal: true

module Example
  module CSRF
    SAFE_METHODS = %w[GET HEAD OPTIONS TRACE].freeze

    module_function

    def valid?(request)
      return true if SAFE_METHODS.include?(request.method)

      token = request.session[CSRF_TOKEN_KEY]
      submitted = request.form["csrf_token"] || request.headers["x-csrf-token"]
      secure_compare(token, submitted)
    end

    def secure_compare(left, right)
      return false if left.to_s.empty? || right.to_s.empty?

      left_bytes = left.to_s.unpack("C*")
      right_bytes = right.to_s.unpack("C*")
      return false unless left_bytes.length == right_bytes.length

      left_bytes.zip(right_bytes).reduce(0) { |result, (a, b)| result | (a ^ b) } == 0
    end
  end
end
