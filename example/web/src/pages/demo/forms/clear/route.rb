# frozen_string_literal: true

def POST(_request)
  Example::Response
    .redirect("/demo/forms")
    .delete_session
end
