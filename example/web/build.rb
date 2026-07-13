# frozen_string_literal: true

require "fileutils"

require_relative "../../lib/klenod"

class BuildLogger
  COLORS = {
    reset: "\e[0m",
    dim: "\e[2m",
    success: "\e[1;32m",
    title: "\e[1;36m",
    generated: "\e[36m",
    written: "\e[32m"
  }.freeze

  def initialize(output: $stdout, env: ENV)
    @output = output
    @env = env
  end

  def step(message)
    output.puts color(:title, message)
  end

  def detail(message)
    output.puts "  #{message}"
  end

  def generated_start(asset)
    output.puts "  #{color(:generated, "generate")} #{asset.output_path} #{color(:dim, asset_details(asset, include_queue: true))}"
  end

  def static_asset(asset)
    output.puts "  #{color(:dim, "static")} #{asset.output_path} #{color(:dim, asset_details(asset))}"
  end

  def written(path)
    output.puts "  #{color(:written, "written")} #{path}"
  end

  def skipped(path)
    output.puts "  #{color(:dim, "skipped")} #{path}"
  end

  private

  attr_reader :output, :env

  def asset_details(asset, include_queue: false)
    details = [asset.metadata[:type], asset.queue_kind].compact
    details = [asset.metadata[:type]].compact unless include_queue
    details.empty? ? "" : "(#{details.join(", ")})"
  end

  def color(name, value)
    return value.to_s if env["NO_COLOR"]

    "#{COLORS.fetch(name)}#{value}#{COLORS.fetch(:reset)}"
  end
end

def log_assets(context, logger)
  context.each_asset do |asset|
    if asset.generated?
      logger.generated_start(asset)
    else
      logger.static_asset(asset)
    end
  end
end

config = Klenod::Build::ConfigLoader.load(File.expand_path("klenod.config.rb", __dir__))
output = config.output_path
assets_dir = config.assets_path
logger = BuildLogger.new

FileUtils.mkdir_p(File.dirname(output))

context = config.context

logger.step("Collecting bundle")
bundle = context.graph.bundle(entrypoints: config.entrypoints)
logger.detail("entrypoints: #{config.entrypoints.join(", ")}")
logger.detail("modules: #{bundle.modules.length}")
logger.detail("assets: #{context.assets.length}")

logger.step("Assets")
log_assets(context, logger)

if assets_dir
  logger.step("Writing assets")
  write_result = context.write_assets(assets_dir)
  write_result.written_paths.each { |path| logger.written(path) }
  write_result.skipped_paths.each { |path| logger.skipped(path) }
end

logger.step("Writing bundle")
File.binwrite(output, Marshal.dump(bundle))
logger.written(output)
