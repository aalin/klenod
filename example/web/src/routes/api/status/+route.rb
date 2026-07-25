# frozen_string_literal: true

def GET(request)
  Example::Response.json(
    {
      status: "ok",
      service: "klenod",
      method: request.method,
      path: request.path,
      query: request.query
    }
  )
end
