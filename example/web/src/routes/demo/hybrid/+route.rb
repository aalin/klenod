def GET(request)
  Response.json(
    {
      type: "hybrid",
      path: request.path,
      request: "api"
    }
  )
end

def PUT(request)
  Response.json(
    {
      type: "hybrid",
      path: request.path,
      method: request.method
    }
  )
end

def OPTIONS(request)
  Response.json(
    {
      type: "hybrid",
      path: request.path,
      method: request.method
    }
  )
end
