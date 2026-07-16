# frozen_string_literal: true

module Example
  SESSION_COOKIE = "klenod_example_session"
  LOCALE_COOKIE = "klenod_example_locale"
  SESSION_SECRET = ENV.fetch("KLENOD_EXAMPLE_SESSION_SECRET", "klenod example development session secret")
  CSRF_TOKEN_KEY = "_csrf_token"
  CONTEXT_KEY = :example_web_context

  class NotFoundError < StandardError; end
end
