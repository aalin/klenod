# frozen_string_literal: true

module Example
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
      @mutex = Mutex.new
    end

    def step(message)
      log color(:title, message)
    end

    def detail(message)
      log "  #{message}"
    end

    def asset(asset)
      marker = asset.generated? ? "generated asset" : "static asset"
      details = asset_details(asset, include_queue: asset.generated?)

      log "  #{color(:dim, marker)} #{asset.output_path} #{color(:dim, details)}"
    end

    def write_start(asset)
      log "  #{color(:written, "write")} #{asset.output_path} #{color(:dim, asset_details(asset))}"
    end

    def generate_start(asset)
      log "  #{color(:generated, "generate")} #{asset.output_path} #{color(:dim, asset_details(asset, include_queue: true))}"
    end

    def written(path)
      log "  #{color(:written, "written")} #{path}"
    end

    def completed(duration)
      log ""
      log "#{color(:success, "Build completed")} #{color(:dim, "(#{format_duration(duration)})")}"
    end

    def skipped(path)
      log "  #{color(:dim, "skipped")} #{path}"
    end

    private

    attr_reader :output, :env, :mutex

    def log(message)
      mutex.synchronize { output.puts(message) }
    end

    def asset_details(asset, include_queue: false)
      details = [asset.metadata[:type], asset.queue_kind].compact
      details = [asset.metadata[:type]].compact unless include_queue
      details.empty? ? "" : "(#{details.join(", ")})"
    end

    def format_duration(duration)
      if duration < 1
        format("%.4fms", duration * 1000)
      else
        format("%.4fs", duration)
      end
    end

    def color(name, value)
      return value.to_s if env["NO_COLOR"]

      "#{COLORS.fetch(name)}#{value}#{COLORS.fetch(:reset)}"
    end
  end

  module BuildLogging
    module_function

    def log_assets(context, logger)
      context.each_asset { |asset| logger.asset(asset) }
    end

    def log_asset_counts(context, logger)
      assets = context.each_asset.to_a
      generated = assets.count(&:generated?)

      logger.detail("static assets: #{assets.length - generated}")
      logger.detail("generated assets: #{generated}")
    end

    def log_asset_write_event(logger, event, asset, path)
      case event
      when :generate_start then logger.generate_start(asset)
      when :write_start then logger.write_start(asset)
      when :written then logger.written(path)
      when :skipped then logger.skipped(path)
      else raise ArgumentError, "unknown asset write event: #{event.inspect}"
      end
    end
  end
end
