# frozen_string_literal: true

def PUT(request)
  response = Example::Framework::Response.redirect(return_to(request))

  case request.form.fetch("value", "system")
  when "light", "dark"
    response.with_cookie(Example::Framework::THEME_COOKIE, request.form.fetch("value"), http_only: false)
  else
    response.delete_cookie(Example::Framework::THEME_COOKIE, http_only: false)
  end
end

def verify_csrf? = false

def return_to(request)
  value = request.form.fetch("return_to", "/").to_s
  return value if value.start_with?("/") && !value.start_with?("//")

  "/"
end
