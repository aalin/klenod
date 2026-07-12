# frozen_string_literal: true

require_relative "../../lib/klenod"

CONFIG_PATH = File.expand_path("klenod.config.rb", __dir__)
HTTP_METHODS = %w[GET POST PUT PATCH DELETE OPTIONS HEAD].freeze

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

def route_rows(config)
  context = config.context
  context.collect(config.entrypoints.fetch(0))
  router = context.exports("virtual:router.rb")::Default

  router.routes.flat_map do |route|
    source_path = context.graph.absolute_path(Klenod::Build::ModuleId.new(route.module_id, nil)).to_s
    methods = route_methods(route, source_path)
    methods = ["-"] if methods.empty?

    methods.map do |method|
      [method, route.path, route_type(route), route.module_id]
    end
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

config = Klenod::Build::ConfigLoader.load(CONFIG_PATH)
print_table(route_rows(config))
