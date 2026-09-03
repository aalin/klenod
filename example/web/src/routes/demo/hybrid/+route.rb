def GET(request)
  Example::Framework::Response.json(
    {
      type: "hybrid",
      path: request.path,
      request: "api"
    }
  )
end

def PUT(request)
  Example::Framework::Response.json(
    {
      type: "hybrid",
      path: request.path,
      method: request.method
    }
  )
end

def OPTIONS(request)
  Example::Framework::Response.json(
    {
      type: "hybrid",
      path: request.path,
      method: request.method
    }
  )
end
