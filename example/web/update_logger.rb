# frozen_string_literal: true

module Example
  class UpdateLogger
    COLORS = {
      reset: "\e[0m",
      dim: "\e[2m",
      success: "\e[1;32m",
      failure: "\e[1;31m",
      changed: "\e[1;33m",
      added: "\e[32m",
      removed: "\e[31m"
    }.freeze

    def initialize(source_dir:, output: $stdout, error_output: $stderr, env: ENV)
      @source_dir = Pathname.new(source_dir).expand_path
      @output = output
      @error_output = error_output
      @env = env
    end

    def log(event:, update:, duration:, &format_error)
      if update.failed?
        error_output.puts "#{color(:failure, "Update ##{event.graph_version} failed")} #{color(:dim, "(#{duration})")}"
        log_trigger_paths(event, error_output)
        update.each_error do |module_id, error|
          message = format_error ? format_error.call(module_id, error) : "#{module_id}: #{error.class}: #{error.message}"
          error_output.puts indent_lines(message, "  ")
        end
      else
        output.puts "#{color(:success, "Update ##{event.graph_version} completed")} #{color(:dim, "(#{duration})")}"
        log_trigger_paths(event, output)
        log_modules(event.result)
        log_assets(event.asset_changes)
        log_asset_files(update)
      end
    end

    private

    attr_reader :source_dir, :output, :error_output, :env

    def log_trigger_paths(event, stream)
      stream.puts "  changed files: #{format_paths(event.changed_paths).join(", ")}" unless event.changed_paths.empty?
      stream.puts "  removed files: #{format_paths(event.removed_paths).join(", ")}" unless event.removed_paths.empty?
    end

    def log_modules(result)
      output.puts "  reloaded: #{format_values(result.reloaded_module_ids).join(", ")}" unless result.reloaded_module_ids.empty?
      output.puts "  reevaluated: #{format_values(result.reevaluated_module_ids).join(", ")}" unless result.reevaluated_module_ids.empty?
      output.puts "  removed modules: #{format_values(result.removed_module_ids).join(", ")}" unless result.removed_module_ids.empty?
    end

    def log_assets(asset_changes)
      return if asset_changes.empty?

      output.puts "  assets:"
      asset_changes.added.each { |path| output.puts "    #{color(:added, "+")} #{color(:added, path)}" }
      asset_changes.changed.each { |path| output.puts "    #{color(:changed, "~")} #{color(:changed, path)}" }
      asset_changes.removed.each { |path| output.puts "    #{color(:removed, "-")} #{color(:removed, path)}" }
    end

    def log_asset_files(update)
      return unless update.asset_files_changed?

      output.puts "  asset files:"
      update.written_asset_paths.each { |path| output.puts "    #{color(:added, "written")} #{path}" }
      update.removed_asset_paths.each { |path| output.puts "    #{color(:removed, "removed")} #{path}" }
    end

    def format_paths(paths)
      paths.map { |path| relative_path(path) }
    end

    def format_values(values)
      values.map(&:to_s)
    end

    def relative_path(path)
      pathname = Pathname.new(path)
      pathname = pathname.expand_path if pathname.absolute?
      pathname.relative_path_from(source_dir).to_s
    rescue ArgumentError
      path.to_s
    end

    def color(name, value)
      return value.to_s if env["NO_COLOR"]

      "#{COLORS.fetch(name)}#{value}#{COLORS.fetch(:reset)}"
    end

    def indent_lines(value, indent)
      value.lines.map { |line| "#{indent}#{line}" }.join
    end
  end
end
