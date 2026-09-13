# frozen_string_literal: true

require "klenod/build/plugins/router_plugin"

module Klenod
  module LSP
    # What the router plugin knows about a module: the route a page or
    # handler serves, the routes a layout wraps, or the special view it is.
    # The manifest is discovered from the pages directory and kept until
    # files change.
    class Routes
      def initialize(workspace)
        @workspace = workspace
        @manifest = nil
        @discovered = false
      end

      def invalidate
        @manifest = nil
        @discovered = false
      end

      def descriptions(module_id)
        manifest = self.manifest
        return [] unless manifest

        id = module_id.to_s
        descriptions = []
        manifest.routes.each do |route|
          descriptions << "Route #{route.path}" if [route.page_module_id, route.handler_module_id].compact.any? { |candidate| candidate.to_s == id }
        end
        wrapped = manifest.routes.count { |route| [*route.layout_module_ids, route.slot_layout_module_id].compact.any? { |candidate| candidate.to_s == id } }
        descriptions << "Layout for #{wrapped} #{(wrapped == 1) ? "route" : "routes"}" if wrapped.positive?
        manifest.special_views.each do |view|
          descriptions << "#{view.kind.to_s.tr("_", " ").capitalize} view for #{view.path}" if view.view_module_id.to_s == id
        end
        descriptions
      end

      # Markdown for a hover on a route module: the route and its params,
      # the page and handler files, and the layouts wrapping it; for a layout,
      # the routes it wraps; for a special view, its kind and scope.
      def hover_markdown(module_id)
        manifest = self.manifest
        return nil unless manifest

        id = module_id.to_s
        sections = []
        manifest.routes.each do |route|
          next unless [route.page_module_id, route.handler_module_id].compact.any? { |candidate| candidate.to_s == id }

          lines = ["**Route** `#{route.path}` · `#{directory_form(route)}`"]
          params = route.params
          lines << "Params: #{params.map { |param| "`#{param.name}` (#{param.kind})" }.join(", ")}" unless params.empty?
          lines << "Page: `#{route.page_module_id.path}`" if route.page_module_id
          lines << "Handler: `#{route.handler_module_id.path}`" if route.handler_module_id
          lines << layouts_line(route.layout_module_ids)
          sections << lines.compact.join("\n\n")
        end

        wrapped = manifest.routes.select { |route| [*route.layout_module_ids, route.slot_layout_module_id].compact.any? { |candidate| candidate.to_s == id } }
        unless wrapped.empty?
          listed = wrapped.first(10).map { |route| "`#{route.path}`" }
          listed << "…" if wrapped.length > 10
          sections << "**Layout** for #{wrapped.length} #{(wrapped.length == 1) ? "route" : "routes"}: #{listed.join(", ")}"
        end

        manifest.special_views.each do |view|
          next unless view.view_module_id.to_s == id

          lines = ["**#{view.kind.to_s.tr("_", " ").capitalize} view** for `#{view.path}`"]
          lines << "Status: #{view.status}" if view.status
          lines << layouts_line(view.layout_module_ids)
          sections << lines.compact.join("\n\n")
        end

        sections.empty? ? nil : sections.join("\n\n---\n\n")
      end

      private

      # The directory spelling of a route, e.g. `pages/docs/[slug]`, next to
      # the URL pattern the router matches, e.g. `/docs/:slug`.
      def directory_form(route)
        File.dirname(route.module_id.path)
      end

      def layouts_line(layout_module_ids)
        return nil if layout_module_ids.nil? || layout_module_ids.empty?

        "Layouts: #{layout_module_ids.map { |layout_id| "`#{layout_id.path}`" }.join(" → ")}"
      end

      def manifest
        return @manifest if @discovered

        @discovered = true
        plugin = @workspace.context.graph.plugins.find { |candidate| candidate.is_a?(Klenod::Build::Plugins::RouterPlugin::Plugin) }
        @manifest = plugin&.discover(source_dir: @workspace.source_dir)
      rescue Klenod::Build::Error
        @manifest = nil
      end
    end
  end
end
