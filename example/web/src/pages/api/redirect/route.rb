# frozen_string_literal: true

def GET(_request)
  Example::Response.redirect("/")
end
