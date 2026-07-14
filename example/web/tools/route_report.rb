# frozen_string_literal: true

module Example
  class RouteReport
    HTTP_METHODS = %w[GET POST PUT PATCH DELETE OPTIONS HEAD].freeze
    TREE_INDENT = "   "
    COLORS = {
      reset: "\e[0m",
      heading: "\e[1;34m",
      method: "\e[1;32m",
      path: "\e[1;36m",
      type: "\e[1;35m",
      layout: "\e[33m",
      source: "\e[2m",
      slot: "\e[35m"
    }.freeze

    def initialize(config, output: $stdout, env: ENV)
      @config = config
      @output = output
      @env = env
    end

    def print
      router = route_context
      print_table(route_rows(router))
      print_route_tree(router)
    end

    private

    attr_reader :config, :output, :env

    def color(name, value)
      return value if env["NO_COLOR"]

      "#{COLORS.fetch(name)}#{value}#{COLORS.fetch(:reset)}"
    end

    def route_methods(source_path)
      return [] unless File.file?(source_path)

      source = File.read(source_path)
      HTTP_METHODS.select { |method| source.match?(/^\s*def\s+#{method}\b/) }
    end

    def route_method_lines(source_path)
      return {} unless File.file?(source_path)

      File
        .readlines(source_path)
        .each_with_index
        .each_with_object({}) do |(line, index), lines|
        HTTP_METHODS.each do |method|
          lines[method] = index + 1 if line.match?(/^\s*def\s+#{method}\b/)
        end
      end
    end

    def route_type(route)
      return "slot" if route.slot_layout_module_id
      return "page+handler" if route.page_module_id && route.handler_module_id
      return "handler" unless route.page_module_id

      "page"
    end

    def route_context
      context = config.context
      context.collect(config.entrypoints.fetch(0))
      context.exports("virtual:router.rb")::Default
    end

    def route_rows(router)
      context = config.context

      router.routes.flat_map do |route|
        rows = []
        rows << ["GET", route.path, route.slot_layout_module_id ? "slot" : "page", route.page_module_id] if route.page_module_id
        if route.handler_module_id
          source_path = context.graph.absolute_path(Klenod::Build::ModuleId.new(route.handler_module_id, nil)).to_s
          methods = route_methods(source_path)
          methods = ["-"] if methods.empty?
          rows.concat(methods.map { |method| [method, route.path, "handler", route.handler_module_id] })
        end

        rows
      end
    end

    def route_groups(router)
      router.routes.group_by(&:path).sort_by do |path, routes|
        primary = routes.find { |route| route.slot_layout_module_id.nil? } || routes.fetch(0)
        [path.split("/").length, path, route_type(primary)]
      end
    end

    def print_table(rows)
      columns = ["METHOD", "PATH", "TYPE", "SOURCE"]
      widths =
        columns.each_index.map do |index|
          ([columns[index]] + rows.map { |row| row.fetch(index) }).map(&:length).max
        end

      output.puts columns.each_with_index.map { |column, index| column.ljust(widths.fetch(index)) }.join("  ")
      output.puts widths.map { |width| "-" * width }.join("  ")
      rows.each do |row|
        output.puts row.each_with_index.map { |value, index| value.ljust(widths.fetch(index)) }.join("  ")
      end
    end

    def print_route_tree(router)
      output.puts
      output.puts color(:heading, "Route tree")

      route_groups(router).each do |_path, routes|
        primary = routes.find { |route| route.slot_layout_module_id.nil? } || routes.fetch(0)
        slot_routes = routes.select(&:slot_layout_module_id).sort_by { |route| slot_name(route) }

        output.puts
        output.puts route_heading(primary)
        print_layout_tree(primary, slot_routes)
      end
    end

    def print_layout_tree(primary, slot_routes)
      layout_ids = primary.layout_module_ids
      leaf_routes =
        [
          *route_leaves(primary),
          *slot_routes.map { |slot_route| slot_leaf(slot_route) }
        ]
      return print_leaf_group(leaf_routes, "") if layout_ids.empty?

      layout_ids.each_with_index do |layout_module_id, index|
        output.puts "#{tree_prefix(index)}└─ #{color(:layout, "layout")} #{color(:source, layout_module_id)}"
        next unless index == layout_ids.length - 1

        print_leaf_group(leaf_routes_for_layout(layout_module_id, leaf_routes), tree_prefix(index + 1))
      end
    end

    def tree_prefix(depth)
      TREE_INDENT * depth
    end

    def route_leaves(route)
      leaves = []
      if route.page_module_id
        leaves << {
          layout_id: route.layout_module_ids.last,
          label: color(:type, "page"),
          source: route.page_module_id
        }
      end
      if route.handler_module_id
        leaves << {
          layout_id: route.layout_module_ids.last,
          label: color(:type, "handler"),
          source: source_for_handler(route)
        }
      end
      leaves
    end

    def slot_leaf(route)
      {
        layout_id: route.slot_layout_module_id,
        label: color(:slot, "slot @#{slot_name(route)}"),
        source: route.page_module_id
      }
    end

    def leaf_routes_for_layout(layout_module_id, leaf_routes)
      leaf_routes.select { |leaf| leaf.fetch(:layout_id) == layout_module_id }
    end

    def print_leaf_group(leaf_routes, prefix)
      leaf_routes.each do |leaf|
        output.puts "#{prefix}#{leaf.fetch(:label)} #{color(:source, leaf.fetch(:source))}"
      end
    end

    def route_methods_for_display(route)
      methods = []
      methods << "GET" if route.page_module_id
      return methods unless route.handler_module_id

      source_path = config.context.graph.absolute_path(Klenod::Build::ModuleId.new(route.handler_module_id, nil)).to_s
      handler_methods = route_methods(source_path)
      methods.concat(handler_methods.empty? ? ["-"] : handler_methods)
      methods.uniq
    end

    def route_heading(route)
      "#{color(:method, route_methods_for_display(route).join(","))} #{color(:path, route.path)} #{color(:type, "(#{route_type(route)})")}"
    end

    def source_for_handler(route)
      source_path = config.context.graph.absolute_path(Klenod::Build::ModuleId.new(route.handler_module_id, nil)).to_s
      lines = route_method_lines(source_path)
      methods = route_methods_for_display(route)
      line = methods.filter_map { |method| lines[method] }.min
      line ? "#{route.handler_module_id}:#{line}" : route.handler_module_id
    end

    def slot_name(route)
      route.segments.find { |segment| segment.kind == :parallel }&.param_name || "default"
    end
  end
end
