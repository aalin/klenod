# frozen_string_literal: true

def POST(_request)
  Example::Response
    .redirect("/forms")
    .delete_session
end
