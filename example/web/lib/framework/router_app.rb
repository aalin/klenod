# frozen_string_literal: true

module Example
  class RouterApp
    def initialize(router:, translations:, default_locale:)
      @router = router
      @routes =
        LocalizedRoutes.new(
          routes: router.routes,
          translations: translations,
          default_locale: default_locale
        )
    end

    def call(raw_request, context)
      path = request_path(raw_request)
      localized = localized_request_path(path)
      match = router.match(localized.path)
      unless match
        not_found_match = router.not_found(localized.path)
        return [404, {"content-type" => "text/plain"}, ["Not found\n"]] unless not_found_match

        request = Request.from(raw_request, params: not_found_match.params, localized: localized)
        return render_page_response(not_found_match, request, context, raw_request: raw_request, status: 404, props: {path: path, status: 404})
      end

      request = Request.from(raw_request, params: match.params, localized: localized)
      return call_route_handler(match.handler, request, vary_accept: hybrid_get_request?(match, request)) if route_handler_request?(match, request)
      return Response.text("Method not allowed\n", status: 405).to_a unless page_method?(match, request)

      representation = preferred_page_representation(request)
      return not_acceptable_response unless representation

      begin
        render_page_response(match, request, context, raw_request: raw_request, representation: representation)
      rescue NotFoundError
        not_found_match = router.not_found(localized.path)
        raise unless not_found_match

        not_found_request = Request.from(raw_request, params: not_found_match.params, localized: localized)
        render_page_response(not_found_match, not_found_request, context, raw_request: raw_request, status: 404, props: {path: path, status: 404})
      rescue => error
        error_match = router.error(localized.path)
        raise unless error_match

        formatted_error = format_render_error(error, context)
        warn formatted_error
        error_request = Request.from(raw_request, params: error_match.params, localized: localized)
        error_props = {path: path, status: 500, error: error, error_details: strip_ansi(formatted_error)}
        if resolution_error?(error)
          error_props[:error_source] = resolution_error_source(error, context)
          error_props[:source_root] = resolution_source_root(context)
        end
        render_page_response(error_match, error_request, context, raw_request: raw_request, status: 500, props: error_props)
      end
    end

    private

    attr_reader :router, :routes

    def render_page_response(match, request, context, raw_request: nil, status: 200, props: {}, representation: nil)
      representation ||= preferred_page_representation(request)
      return not_acceptable_response unless representation

      if representation == :markdown
        return render_markdown_response(match, request, status: status, props: props)
      end

      render_html_response(match, request, context, raw_request: raw_request, status: status, props: props)
    end

    def render_markdown_response(match, request, status:, props:)
      request = request.with(representation: :markdown)
      body =
        Context.with(request: request, routes: routes) do
          MarkdownRenderer.render(page_instance(match.page, props).render)
        end

      commit_session(
        Response.markdown(body, status: status, headers: {"vary" => "Cookie, Accept"}),
        request
      ).to_a
    end

    def render_html_response(match, request, context, raw_request:, status:, props:)
      request = request.with(representation: :html)
      page = match.page
      layouts = match.layouts
      prepare_slot_pages(match, layouts)
      route_asset_module_ids = route_asset_module_ids_for(match)
      css_asset_references = context.asset_references_for_module(route_asset_module_ids, type: :css)
      javascript_asset_references = context.asset_references_for_module(route_asset_module_ids, type: :javascript)
      early_hints_sent = send_early_hints(raw_request, css_asset_references, javascript_asset_references)

      body =
        Context.with(request: request, routes: routes) do
          body_node = render_descriptor_tree(match, page, layouts, request, props)
          render_html_string(body_node)
        end

      response = commit_session(
        Response.html(
          <<~HTML,
            <!doctype html>
            <html#{html_theme_attributes(request)}>
              <head>
                <title>Klenod example</title>
                #{stylesheet_links(css_asset_references)}
                #{module_script_tags(javascript_asset_references)}
              </head>
              #{body}
            </html>
          HTML
          status: status,
          headers: html_response_headers(css_asset_references, javascript_asset_references, include_link: !early_hints_sent)
        ),
        request
      )
      response.to_a
    end

    def html_theme_attributes(request)
      theme = request.cookies.fetch(THEME_COOKIE, nil)
      return "" unless %w[light dark].include?(theme)

      %( data-theme="#{theme}")
    end

    def page_instance(page, props)
      component_instance(page, **props)
    end

    def component_instance(component, **props)
      if component.respond_to?(:instantiate)
        component.instantiate(**props)
      else
        component.new(**props)
      end
    end

    def render_descriptor_tree(match, page, layouts, request, props)
      renderer = -> { page_instance(page, props).render }
      layouts.reverse_each do |layout|
        renderer = layout_renderer(layout, renderer, match, request)
      end
      renderer.call
    end

    def layout_renderer(layout, inner_renderer, match, request)
      slots = render_slots(match, layout, request).merge(nil => inner_renderer)
      -> { component_instance(layout, slots: slots).render }
    end

    def render_html_string(body_node)
      H.render(body_node)
    end

    def format_render_error(error, context)
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

        if resolution_error?(error) && defined?(Klenod::Build::ResolutionErrorFormatter)
          return Klenod::Build::ResolutionErrorFormatter.format(
            error,
            source_root: resolution_source_root(context),
            ansi: !ENV.key?("NO_COLOR")
          )
        end

        return Klenod::Runtime::BacktraceRewriter.new(mods || {}).format_exception(error)
      end

      error.full_message
    end

    def strip_ansi(value)
      value.gsub(/\e\[[0-9;]*m/, "")
    end

    def resolution_error?(error)
      defined?(Klenod::Build::ResolveError) && error.is_a?(Klenod::Build::ResolveError) && error.resolution_failure?
    end

    def resolution_error_source(error, context)
      location = error.source_location
      return nil unless location&.line && context.respond_to?(:graph)

      module_id = Klenod::Build::ModuleId.parse(location.path)
      source_path = context.graph.absolute_path(module_id)
      return nil unless source_path.file?

      {path: location.path, source: source_path.read, line: location.line}
    rescue Klenod::Build::ResolveError, ArgumentError
      nil
    end

    def resolution_source_root(context)
      context.graph.source_dir if context.respond_to?(:graph)
    end

    def stylesheet_links(asset_references)
      asset_references
        .map { |reference| %(<link rel="stylesheet" href="#{reference.asset.output_path}" data-index="#{reference.index}">) }
        .join("\n")
    end

    def module_script_tags(asset_references)
      asset_references
        .map { |reference| %(<script type="module" src="#{reference.asset.output_path}" data-index="#{reference.index}"></script>) }
        .join("\n")
    end

    def html_response_headers(css_asset_references, javascript_asset_references, include_link: true)
      headers = {"vary" => "Cookie, Accept"}
      link = asset_preload_link_header(css_asset_references, javascript_asset_references)
      headers["link"] = link if include_link && !link.empty?
      headers
    end

    def send_early_hints(raw_request, css_asset_references, javascript_asset_references)
      return unless raw_request&.respond_to?(:send_interim_response)

      link = asset_preload_link_header(css_asset_references, javascript_asset_references)
      return false if link.empty?

      raw_request.send_interim_response(103, [["link", link]])
      true
    rescue
      false
    end

    def asset_preload_link_header(css_asset_references, javascript_asset_references)
      [
        *stylesheet_preload_links(css_asset_references),
        *asset_preload_links(javascript_asset_references),
        *modulepreload_links(javascript_asset_references)
      ].join(", ")
    end

    def stylesheet_preload_links(asset_references)
      asset_references
        .map { |reference| %(<#{reference.asset.output_path}>; rel=preload; as=style) }
    end

    def modulepreload_links(asset_references)
      asset_references
        .map { |reference| %(<#{reference.asset.output_path}>; rel=modulepreload) }
    end

    def asset_preload_links(asset_references)
      asset_references.flat_map do |reference|
        Array(reference.asset.metadata[:preload_assets]).map do |preload|
          %(<#{preload.fetch(:path)}>; rel=preload; as=#{preload.fetch(:as)})
        end
      end
    end

    def request_path(raw_request)
      raw_path = raw_request&.path.to_s
      raw_path = "/" if raw_path.empty?
      raw_path.split("?", 2).fetch(0)
    end

    def localized_request_path(path)
      routes.canonicalize_path(path)
    end

    def call_route_handler(handler, request, vary_accept: false)
      method_name = request_method(request)
      return Response.text("Method not allowed\n", status: 405).to_a unless handler.method_defined?(method_name)

      route_handler = handler.new
      return Response.text("Invalid CSRF token\n", status: 403).to_a unless csrf_valid_for_route?(route_handler, request)

      response =
        Context.with(request: request, routes: routes) do
          normalize_response(route_handler.public_send(method_name, request), request)
        end
      vary_accept ? with_vary_accept(response) : response
    end

    def csrf_valid_for_route?(route_handler, request)
      return true if route_handler.respond_to?(:verify_csrf?) && !route_handler.verify_csrf?

      CSRF.valid?(request)
    end

    def request_method(request)
      method = request&.method
      method.to_s.empty? ? "GET" : method.to_s.upcase
    end

    def route_handler_request?(match, request)
      return false unless match.handler
      return true unless match.page

      method = request_method(request)
      return true if %w[PUT PATCH DELETE OPTIONS].include?(method)
      return false unless %w[GET POST HEAD].include?(method)

      !preferred_page_representation(request, require_top_match: true)
    end

    def page_method?(match, request)
      match.page && %w[GET POST HEAD].include?(request_method(request))
    end

    def hybrid_get_request?(match, request)
      match.page && request_method(request) == "GET"
    end

    def preferred_page_representation(request, require_top_match: false)
      accept = request.headers.fetch("accept", nil).to_s
      RepresentationNegotiator::PAGE.preferred(accept, default: :html, require_top_match: require_top_match)
    end

    def not_acceptable_response
      Response.text(
        "This resource is available in:\n- text/html\n- text/markdown\n",
        status: 406,
        headers: {"vary" => "Accept", "cache-control" => "no-store"}
      ).to_a
    end

    def with_vary_accept(response)
      status, headers, body = response
      vary = headers.fetch("vary", nil)
      return response if vary.to_s.split(",").map { |value| value.strip.downcase }.include?("accept")

      [status, headers.merge("vary" => [vary, "Accept"].compact.join(", ")), body]
    end

    def normalize_response(response, request)
      return commit_session(response, request).to_a if response.is_a?(Response)
      return response if response.is_a?(Array) && response.length == 3
      return [204, {}, []] if response.nil?

      [200, {"content-type" => "text/plain; charset=utf-8"}, [response.to_s]]
    end

    def commit_session(response, request)
      return response unless request.session.dirty?

      response.with_session(request)
    end

    def render_slots(match, layout, request)
      match
        .slots
        .select { |_name, slot_match| slot_for_layout?(slot_match, layout) }
        .to_h do |name, slot_match|
        [
          name,
          lambda do
            Context.with(request: request.with_params(slot_match.params)) do
              slot_match
                .page
                .new
                .render
            end
          end
        ]
      end
    end

    def prepare_slot_pages(match, layouts)
      layouts.each do |layout|
        match.slots.each_value do |slot_match|
          slot_match.page if slot_for_layout?(slot_match, layout)
        end
      end
    end

    def route_asset_module_ids_for(match)
      [
        *match.route.layout_module_ids,
        match.route.module_id,
        *slot_asset_module_ids_for(match)
      ].compact.uniq
    end

    def slot_asset_module_ids_for(match)
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

    def slot_for_layout?(slot_match, layout)
      slot_match.layout_module_id && layout.module_path.end_with?(slot_match.layout_module_id)
    end
  end
end
