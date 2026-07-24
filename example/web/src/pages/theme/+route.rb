# frozen_string_literal: true

def GET(request)
  response = Example::Response.redirect(return_to(request))

  case request.query.fetch("value", "system")
  when "light", "dark"
    response.with_cookie(Example::THEME_COOKIE, request.query.fetch("value"), http_only: false)
  else
    response.delete_cookie(Example::THEME_COOKIE, http_only: false)
  end
end

def return_to(request)
  value = request.query.fetch("return_to", "/").to_s
  return value if value.start_with?("/") && !value.start_with?("//")

  "/"
end
