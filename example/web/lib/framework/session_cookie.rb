# frozen_string_literal: true

require "json"
require "rbnacl"

module Example
  module SessionCookie
    module_function

    def encode(session)
      payload = JSON.generate(session.to_h)
      nonce = RbNaCl::Random.random_bytes(RbNaCl::SecretBox.nonce_bytes)
      encrypted = secret_box.encrypt(nonce, payload)

      encode64("#{nonce}#{encrypted}")
    end

    def decode(cookie)
      return {} if cookie.to_s.empty?

      payload = decode64(cookie)
      nonce = payload.byteslice(0, RbNaCl::SecretBox.nonce_bytes)
      encrypted = payload.byteslice(RbNaCl::SecretBox.nonce_bytes..)

      JSON.parse(secret_box.decrypt(nonce, encrypted))
    rescue ArgumentError, JSON::ParserError, RbNaCl::CryptoError
      {}
    end

    def secret_box
      @secret_box ||= RbNaCl::SecretBox.new(RbNaCl::Hash.sha256(SESSION_SECRET))
    end

    def encode64(value)
      [value].pack("m0").tr("+/", "-_").delete("=")
    end

    def decode64(value)
      value = value.tr("-_", "+/")
      value = value.ljust(value.length + ((4 - value.length) % 4), "=")
      value.unpack1("m0")
    end
  end
end
