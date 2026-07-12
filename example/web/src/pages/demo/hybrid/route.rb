def GET(request)
  Example::Response.json(
    {
      type: "hybrid",
      path: request.path,
      request: "api"
    }
  )
end

def PUT(request)
  Example::Response.json(
    {
      type: "hybrid",
      path: request.path,
      method: request.method
    }
  )
end

def OPTIONS(request)
  Example::Response.json(
    {
      type: "hybrid",
      path: request.path,
      method: request.method
    }
  )
end
