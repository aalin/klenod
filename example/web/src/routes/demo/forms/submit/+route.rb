# frozen_string_literal: true

def POST(request)
  name = request.form.fetch("name", "").strip
  request.session["name"] = name unless name.empty?

  Example::Framework::Response
    .redirect(localized_path("/demo/forms"))
    .with_session(request)
end
