# frozen_string_literal: true

LOCALES = %w[en-US sv-SE].freeze

def POST(request)
  locale = request.form.fetch("locale", "").to_s
  response = Example::Response.redirect(redirect_location(request))
  return response unless LOCALES.include?(locale)

  response.with_cookie(Example::LOCALE_COOKIE, locale, http_only: false)
end

def redirect_location(request)
  referer = request.headers.fetch("referer", "")
  return "/demo/translations" unless referer.start_with?("/")

  referer
end
