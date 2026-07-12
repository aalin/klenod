# frozen_string_literal: true

require_relative "../../lib/klenod"

CONFIG_PATH = File.expand_path("klenod.config.rb", __dir__)
HTTP_METHODS = %w[GET POST PUT PATCH DELETE OPTIONS HEAD].freeze
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

def color(name, value)
  return value if ENV["NO_COLOR"]

  "#{COLORS.fetch(name)}#{value}#{COLORS.fetch(:reset)}"
end

def route_methods(route, source_path)
  return ["GET"] unless route.kind == :handler
  return [] unless File.file?(source_path)

  source = File.read(source_path)
  HTTP_METHODS.select { |method| source.match?(/^\s*def\s+#{method}\b/) }
end

def route_type(route)
  return "handler" if route.kind == :handler
  return "slot" if route.slot_layout_module_id

  "page"
end

def route_context(config)
  context = config.context
  context.collect(config.entrypoints.fetch(0))
  context.exports("virtual:router.rb")::Default
end

def route_rows(router, config)
  context = config.context

  router.routes.flat_map do |route|
    source_path = context.graph.absolute_path(Klenod::Build::ModuleId.new(route.module_id, nil)).to_s
    methods = route_methods(route, source_path)
    methods = ["-"] if methods.empty?

    methods.map do |method|
      [method, route.path, route_type(route), route.module_id]
    end
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

  puts columns.each_with_index.map { |column, index| column.ljust(widths.fetch(index)) }.join("  ")
  puts widths.map { |width| "-" * width }.join("  ")
  rows.each do |row|
    puts row.each_with_index.map { |value, index| value.ljust(widths.fetch(index)) }.join("  ")
  end
end

def print_route_tree(router, config)
  puts
  puts color(:heading, "Route tree")

  route_groups(router).each do |path, routes|
    primary = routes.find { |route| route.slot_layout_module_id.nil? } || routes.fetch(0)
    slot_routes = routes.select(&:slot_layout_module_id).sort_by { |route| slot_name(route) }

    puts
    puts "#{color(:path, path)} #{color(:type, "(#{route_type(primary)})")}"
    primary.layout_module_ids.each_with_index do |layout_module_id, index|
      puts "#{branch(index, primary.layout_module_ids.length + 1)}#{color(:layout, "layout")} #{color(:source, layout_module_id)}"
    end
    puts "#{branch(primary.layout_module_ids.length, primary.layout_module_ids.length + 1)}#{color(:method, route_methods_for_display(primary, config).join(","))} #{color(:type, route_type(primary))} #{color(:source, primary.module_id)}"

    slot_routes.each do |slot_route|
      puts "  #{color(:slot, "slot @#{slot_name(slot_route)}")} -> #{color(:layout, slot_route.slot_layout_module_id)}"
      puts "    #{color(:method, "GET")} #{color(:type, "page")} #{color(:source, slot_route.module_id)}"
    end
  end
end

def route_methods_for_display(route, config)
  return ["GET"] unless route.kind == :handler

  source_path = config.context.graph.absolute_path(Klenod::Build::ModuleId.new(route.module_id, nil)).to_s
  methods = route_methods(route, source_path)
  methods.empty? ? ["-"] : methods
end

def branch(index, count)
  if index == count - 1
    "└─ "
  else
    "├─ "
  end
end

def slot_name(route)
  route.segments.find { |segment| segment.kind == :parallel }&.param_name || "default"
end

config = Klenod::Build::ConfigLoader.load(CONFIG_PATH)
router = route_context(config)
print_table(route_rows(router, config))
print_route_tree(router, config)
