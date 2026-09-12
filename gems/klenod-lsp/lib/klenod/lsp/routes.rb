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

      private

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
