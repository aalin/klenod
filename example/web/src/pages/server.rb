# frozen_string_literal: true

Router = import("virtual:router")
ROUTE_TRANSLATIONS = {
  "en" => import("/routes.intl.en.toml"),
  "sv" => import("/routes.intl.sv.toml")
}
Routes = Example::LocalizedRoutes.new(
  routes: Router::Default.routes,
  translations: ROUTE_TRANSLATIONS,
  default_locale: "en"
)

def self.call(raw_request, context)
  path = request_path(raw_request)
  localized = localized_request_path(raw_request, path)
  match = Router::Default.match(localized.path)
  unless match
    not_found_match = Router::Default.not_found(localized.path)
    return [404, {"content-type" => "text/plain"}, ["Not found\n"]] unless not_found_match

    request = Example::Request.from(raw_request, params: not_found_match.params, localized: localized)
    return render_page_response(not_found_match, request, context, raw_request: raw_request, status: 404, props: {path: path, status: 404})
  end

  request = Example::Request.from(raw_request, params: match.params, localized: localized)
  return call_route_handler(match.handler, request, vary_accept: hybrid_get_request?(match, request)) if route_handler_request?(match, request)
  return Example::Response.text("Method not allowed\n", status: 405).to_a unless page_request?(match, request)

  begin
    render_page_response(match, request, context, raw_request: raw_request)
  rescue Example::NotFoundError
    not_found_match = Router::Default.not_found(localized.path)
    raise unless not_found_match

    not_found_request = Example::Request.from(raw_request, params: not_found_match.params, localized: localized)
    render_page_response(not_found_match, not_found_request, context, raw_request: raw_request, status: 404, props: {path: path, status: 404})
  rescue => error
    error_match = Router::Default.error(localized.path)
    raise unless error_match

    formatted_error = format_render_error(error, context)
    warn formatted_error
    error_request = Example::Request.from(raw_request, params: error_match.params, localized: localized)
    render_page_response(error_match, error_request, context, raw_request: raw_request, status: 500, props: {path: path, status: 500, error: error, error_details: strip_ansi(formatted_error)})
  end
end

def self.render_page_response(match, request, context, raw_request: nil, status: 200, props: {})
  page = match.page
  layouts = match.layouts
  prepare_slot_pages(match, layouts)
  css_asset_references = context.asset_references_for_module(css_module_ids_for(match), type: :css)
  early_hints_sent = send_early_hints(raw_request, css_asset_references)

  body =
    Example::Context.with(request: request, routes: Routes) do
      body =
        page_instance(page, props)
          .render
      layouts
        .reverse_each
        .reduce(body) do |inner, layout|
        component_instance(layout, children: [inner], slots: render_slots(match, layout, request)).render
      end
    end

  response = commit_session(
    Example::Response.html(
      <<~HTML,
        <!doctype html>
        <html#{html_theme_attributes(request)}>
          <head>
            <title>Klenod example</title>
            #{stylesheet_links(css_asset_references)}
          </head>
          #{body}
        </html>
      HTML
      status: status,
      headers: html_response_headers(css_asset_references, include_link: !early_hints_sent)
    ),
    request
  )
  response.to_a
end

def self.html_theme_attributes(request)
  theme = request.cookies.fetch(Example::THEME_COOKIE, nil)
  return "" unless %w[light dark].include?(theme)

  %( data-theme="#{theme}")
end

def self.page_instance(page, props)
  component_instance(page, **props)
end

def self.component_instance(component, **props)
  if component.respond_to?(:instantiate)
    component.instantiate(**props)
  else
    component.new(**props)
  end
end

def self.format_render_error(error, context)
  if defined?(Klenod::Runtime::BacktraceRewriter)
    mods =
      if context.respond_to?(:graph)
        context.graph.mods.each_with_object({}) do |(module_id, mod), index|
          index[module_id.to_s] = mod
          index[module_id.path] = mod
        end
      elsif context.respond_to?(:modules)
        context.modules
      end

    return Klenod::Runtime::BacktraceRewriter.new(mods || {}).format_exception(error)
  end

  error.full_message
end

def self.strip_ansi(value)
  value.gsub(/\e\[[0-9;]*m/, "")
end

def self.module_path
  __FILE__
end

def self.stylesheet_links(asset_references)
  asset_references
    .map { |reference| %(<link rel="stylesheet" href="#{reference.asset.output_path}" data-index="#{reference.index}">) }
    .join("\n")
end

def self.html_response_headers(css_asset_references, include_link: true)
  headers = {"vary" => "Cookie"}
  link = stylesheet_preload_link_header(css_asset_references)
  headers["link"] = link if include_link && !link.empty?
  headers
end

def self.send_early_hints(raw_request, css_asset_references)
  return unless raw_request&.respond_to?(:send_interim_response)

  link = stylesheet_preload_link_header(css_asset_references)
  return false if link.empty?

  raw_request.send_interim_response(103, [["link", link]])
  true
rescue
  false
end

def self.stylesheet_preload_link_header(asset_references)
  asset_references
    .map { |reference| %(<#{reference.asset.output_path}>; rel=preload; as=style) }
    .join(", ")
end

def self.request_path(raw_request)
  raw_path = raw_request&.path.to_s
  raw_path = "/" if raw_path.empty?
  raw_path.split("?", 2).fetch(0)
end

def self.localized_request_path(raw_request, path)
  Routes.canonicalize_path(path)
end

def self.call_route_handler(handler, request, vary_accept: false)
  method_name = request_method(request)
  return Example::Response.text("Method not allowed\n", status: 405).to_a unless handler.method_defined?(method_name)
  return Example::Response.text("Invalid CSRF token\n", status: 403).to_a unless Example::CSRF.valid?(request)

  response =
    Example::Context.with(request: request, routes: Routes) do
      normalize_response(handler.new.public_send(method_name, request), request)
    end
  vary_accept ? with_vary_accept(response) : response
end

def self.request_method(request)
  method = request&.method
  method.to_s.empty? ? "GET" : method.to_s.upcase
end

def self.route_handler_request?(match, request)
  return false unless match.handler
  return true unless match.page

  method = request_method(request)
  return true if %w[PUT PATCH DELETE OPTIONS].include?(method)
  return false unless %w[GET POST HEAD].include?(method)

  !accepts_html?(request)
end

def self.page_request?(match, request)
  return false unless match.page
  return true unless match.handler

  %w[GET POST HEAD].include?(request_method(request)) && accepts_html?(request)
end

def self.hybrid_get_request?(match, request)
  match.page && request_method(request) == "GET"
end

def self.accepts_html?(request)
  accept = request.headers.fetch("accept", nil).to_s
  return true if accept.empty?

  preferred_accept_type(accept) == "text/html"
end

def self.preferred_accept_type(accept)
  accept
    .split(",")
    .map
    .with_index { |entry, index| accept_entry(entry, index) }
    .compact
    .max_by { |entry| [entry.fetch(:quality), -entry.fetch(:index)] }
    &.fetch(:type, nil)
end

def self.accept_entry(entry, index)
  type, *params = entry.strip.split(";").map(&:strip)
  return nil if type.empty?

  quality =
    params
      .find { |param| param.start_with?("q=") }
      &.delete_prefix("q=")
      &.to_f || 1.0
  {type:, quality:, index:}
end

def self.with_vary_accept(response)
  status, headers, body = response
  vary = headers.fetch("vary", nil)
  return response if vary.to_s.split(",").map { |value| value.strip.downcase }.include?("accept")

  [status, headers.merge("vary" => [vary, "Accept"].compact.join(", ")), body]
end

def self.normalize_response(response, request)
  return commit_session(response, request).to_a if response.is_a?(Example::Response)
  return response if response.is_a?(Array) && response.length == 3
  return [204, {}, []] if response.nil?

  [200, {"content-type" => "text/plain; charset=utf-8"}, [response.to_s]]
end

def self.commit_session(response, request)
  return response unless request.session.dirty?

  response.with_session(request)
end

def self.render_slots(match, layout, request)
  match
    .slots
    .select { |_name, slot_match| slot_for_layout?(slot_match, layout) }
    .to_h do |name, slot_match|
    [
      name,
      [
        Example::Context.with(request: request.with_params(slot_match.params)) do
          slot_match
            .page
            .new
            .render
        end
      ]
    ]
  end
end

def self.prepare_slot_pages(match, layouts)
  layouts.each do |layout|
    match.slots.each_value do |slot_match|
      slot_match.page if slot_for_layout?(slot_match, layout)
    end
  end
end

def self.css_module_ids_for(match)
  [
    *match.route.layout_module_ids,
    match.route.module_id,
    *slot_css_module_ids_for(match)
  ].compact.uniq
end

def self.slot_css_module_ids_for(match)
  rendered_layout_ids = match.route.layout_module_ids

  match
    .slots
    .sort_by { |name, _slot_match| name.to_s }
    .flat_map do |_name, slot_match|
    next [] unless rendered_layout_ids.include?(slot_match.layout_module_id)

    [
      *slot_match.route.layout_module_ids,
      slot_match.route.module_id
    ]
  end
end

def self.slot_for_layout?(slot_match, layout)
  slot_match.layout_module_id && layout.module_path.end_with?(slot_match.layout_module_id)
end
