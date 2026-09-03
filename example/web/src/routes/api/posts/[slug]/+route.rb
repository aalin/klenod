# frozen_string_literal: true

def GET(request)
  Example::Framework::Response.json(
    {
      slug: request.params.fetch(:slug),
      path: request.path
    }
  )
end
