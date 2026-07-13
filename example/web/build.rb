# frozen_string_literal: true

require "async"
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

  def generated_done(asset, duration)
    output.puts "    #{color(:success, "done")} #{asset.output_path} #{bytesize(asset.bytes)} #{color(:dim, "(#{duration})")}"
  end

  def static_asset(asset)
    output.puts "  #{color(:dim, "static")} #{asset.output_path} #{color(:dim, asset_details(asset))}"
  end

  def written(path)
    output.puts "  #{color(:written, "written")} #{path}"
  end

  private

  attr_reader :output, :env

  def asset_details(asset, include_queue: false)
    details = [asset.metadata[:type], asset.queue_kind].compact
    details = [asset.metadata[:type]].compact unless include_queue
    details.empty? ? "" : "(#{details.join(", ")})"
  end

  def bytesize(bytes)
    "#{bytes.bytesize} bytes"
  end

  def color(name, value)
    return value.to_s if env["NO_COLOR"]

    "#{COLORS.fetch(name)}#{value}#{COLORS.fetch(:reset)}"
  end
end

def duration_ms(start_time)
  format("%.4fms", (Process.clock_gettime(Process::CLOCK_MONOTONIC) - start_time) * 1000)
end

def with_async_task(&block)
  enabled = Warning[:experimental]
  Warning[:experimental] = false
  Async(&block).wait
ensure
  Warning[:experimental] = enabled
end

def generate_assets(context, logger)
  generated_assets = context.each_asset.select(&:generated?)
  static_assets = context.each_asset.reject(&:generated?)

  static_assets.each { |asset| logger.static_asset(asset) }
  return if generated_assets.empty?

  with_async_task do |task|
    generated_assets
      .map do |asset|
        task.async do
          logger.generated_start(asset)
          start_time = Process.clock_gettime(Process::CLOCK_MONOTONIC)
          asset.wait
          logger.generated_done(asset, duration_ms(start_time))
        end
      end
      .each(&:wait)
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

logger.step("Generating assets")
generate_assets(context, logger)

if assets_dir
  logger.step("Writing assets")
  context.write_assets(assets_dir).written_paths.each { |path| logger.written(path) }
end

logger.step("Writing bundle")
File.binwrite(output, Marshal.dump(bundle))
logger.written(output)
