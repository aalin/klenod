# frozen_string_literal: true

require "klenod/runtime"

module Klenod
  module Build
    class Graphviz
      MODULE_STYLES = {
        ".rb" => {fillcolor: "#d7ecff", color: "#3a77b5"},
        ".haml" => {fillcolor: "#f4dcff", color: "#9b52b8"},
        ".css" => {fillcolor: "#dcfce7", color: "#31a46a"},
        ".json" => {fillcolor: "#fff3bf", color: "#c28f00"},
        ".toml" => {fillcolor: "#fff3bf", color: "#c28f00"},
        ".yaml" => {fillcolor: "#fff3bf", color: "#c28f00"},
        ".yml" => {fillcolor: "#fff3bf", color: "#c28f00"}
      }.freeze

      VIRTUAL_STYLE = {fillcolor: "#eceff4", color: "#667085"}.freeze
      ASSET_STYLE = {fillcolor: "#ffe4d6", color: "#e26d39"}.freeze
      DEFAULT_MODULE_STYLE = {fillcolor: "#f7f7f7", color: "#8a8a8a"}.freeze

      def self.call(bundle, include_assets: true)
        new(bundle, include_assets: include_assets).to_dot
      end

      def initialize(bundle, include_assets: true)
        @bundle = bundle
        @include_assets = include_assets
      end

      def to_dot
        lines = [
          "digraph klenod {",
          "  graph [rankdir=LR, bgcolor=\"transparent\", pad=\"0.4\", nodesep=\"0.45\", ranksep=\"0.8\"];",
          "  node [shape=box, style=\"rounded,filled\", fontname=\"Menlo\", fontsize=10, margin=\"0.08,0.05\"];",
          "  edge [fontname=\"Menlo\", fontsize=9, color=\"#667085\", arrowsize=0.7];"
        ]

        module_ids.each { |id| lines << module_node(id) }
        lines.concat(asset_nodes) if @include_assets
        lines.concat(import_edges)
        lines.concat(asset_edges) if @include_assets
        lines << "}"
        "#{lines.join("\n")}\n"
      end

      private

      def module_ids
        @bundle.modules.keys.sort
      end

      def module_node(id)
        spec = @bundle.modules.fetch(id)
        style = module_style(id)
        attributes = {
          label: module_label(spec),
          fillcolor: style.fetch(:fillcolor),
          color: style.fetch(:color),
          penwidth: entrypoint?(id) ? "2.2" : "1.2"
        }

        "  #{node_id(id)} [#{dot_attributes(attributes)}];"
      end

      def asset_nodes
        @bundle.assets.values.sort_by(&:output_path).map do |asset|
          "  #{asset_node_id(asset)} [#{dot_attributes(asset_attributes(asset))}];"
        end
      end

      def import_edges
        module_ids.flat_map do |id|
          @bundle.modules.fetch(id).imports.values.map do |import|
            import = import_spec(import)
            next unless @bundle.modules.key?(import.target_id)

            attributes = {
              color: import.eager ? "#475467" : "#7a5af8",
              style: import.eager ? "solid" : "dashed"
            }
            attributes[:label] = "lazy" unless import.eager

            "  #{node_id(id)} -> #{node_id(import.target_id)} [#{dot_attributes(attributes)}];"
          end
        end.compact
      end

      def asset_edges
        @bundle.assets.values.sort_by(&:output_path).filter_map do |asset|
          owner = asset_owner(asset)
          next unless owner

          attributes = {
            color: "#e26d39",
            style: "dotted",
            label: "asset"
          }
          "  #{owner_node_id(owner)} -> #{asset_node_id(asset)} [#{dot_attributes(attributes)}];"
        end
      end

      def asset_owner(asset)
        return [:module, asset.logical_name] if @bundle.modules.key?(asset.logical_name)

        google_fonts_css_asset_owner(asset) || query_module_id_for(asset.logical_name)
      end

      def google_fonts_css_asset_owner(asset)
        return nil unless asset.metadata[:google_fonts] && asset.metadata[:type] == :font

        css_asset = @bundle.assets.values.find do |candidate|
          candidate.metadata[:google_fonts] &&
            candidate.metadata[:type] == :css &&
            Array(candidate.metadata[:font_source_urls]).include?(google_fonts_source_url(asset))
        end
        [:asset, css_asset] if css_asset
      end

      def google_fonts_source_url(asset)
        asset.metadata[:source_url]
      end

      def query_module_id_for(logical_name)
        module_id = query_module_ids_by_path.fetch(logical_name, nil)
        [:module, module_id] if module_id
      end

      def query_module_ids_by_path
        @query_module_ids_by_path ||=
          module_ids.each_with_object({}) do |id, index|
            path, query = id.split("?", 2)
            next unless query

            index[path] ||= id
          end
      end

      def owner_node_id(owner)
        type, value = owner
        case type
        when :module then node_id(value)
        when :asset then asset_node_id(value)
        else raise ArgumentError, "unknown graph owner: #{owner.inspect}"
        end
      end

      def import_spec(import)
        case import
        when Runtime::ImportSpec
          import
        else
          Runtime::ImportSpec.new(import.to_s, nil, true)
        end
      end

      def module_label(spec)
        label = display_path(spec.source_path || spec.id)
        type = module_type(spec.id)
        entrypoint?(spec.id) ? "#{label}\n#{type} entrypoint" : "#{label}\n#{type}"
      end

      def asset_attributes(asset)
        ASSET_STYLE.merge(
          label: "#{display_path(asset.output_path)}\n#{asset.content_type || "asset"}",
          shape: "note"
        )
      end

      def module_style(id)
        return VIRTUAL_STYLE if id.start_with?("virtual:")

        MODULE_STYLES.fetch(File.extname(id), DEFAULT_MODULE_STYLE)
      end

      def module_type(id)
        return "virtual" if id.start_with?("virtual:")

        ext = File.extname(id)
        ext.empty? ? "module" : ext.delete_prefix(".")
      end

      def entrypoint?(id)
        entrypoint_ids.include?(id)
      end

      def entrypoint_ids
        @entrypoint_ids ||=
          if @bundle.entrypoints.respond_to?(:values)
            @bundle.entrypoints.values
          else
            @bundle.entrypoints
          end
      end

      def display_path(path)
        path = path.to_s
        return path unless @bundle.source_root

        root = File.expand_path(@bundle.source_root)
        expanded = File.expand_path(path)
        return expanded.delete_prefix("#{root}/") if expanded.start_with?("#{root}/")

        path
      end

      def node_id(id)
        "mod_#{dot_identifier(id)}"
      end

      def asset_node_id(asset)
        "asset_#{dot_identifier(asset.output_path)}"
      end

      def dot_identifier(value)
        value.to_s.bytes.map { |byte| byte.to_s(16).rjust(2, "0") }.join
      end

      def dot_attributes(attributes)
        attributes.map { |key, value| "#{key}=#{dot_value(value)}" }.join(", ")
      end

      def dot_value(value)
        %("#{dot_escape(value)}")
      end

      def dot_escape(value)
        value.to_s.gsub(/[\\"]/) { |char| "\\#{char}" }.gsub("\n", "\\n")
      end
    end
  end
end
