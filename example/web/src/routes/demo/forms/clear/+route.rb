# frozen_string_literal: true

def POST(_request)
  Example::Framework::Response
    .redirect(localized_path("/demo/forms"))
    .delete_session
end
