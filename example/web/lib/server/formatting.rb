# frozen_string_literal: true

module Example
  module ServerFormatting
    module_function

    def indent_lines(value, indent)
      value.lines.map { |line| "#{indent}#{line}" }.join
    end

    def strip_ansi(value)
      value.gsub(/\e\[[0-9;]*m/, "")
    end

    def duration_ms(start_time)
      format("%.4fms", (Process.clock_gettime(Process::CLOCK_MONOTONIC) - start_time) * 1000)
    end

    def color_status(status)
      color =
        case status
        when 200..299 then 32
        when 300..399 then 36
        when 400..499 then 33
        else 31
        end

      "\e[#{color}m#{status}\e[0m"
    end

    def color(name, value)
      return value.to_s if ENV["NO_COLOR"]

      colors = {
        reset: "\e[0m",
        dim: "\e[2m",
        title: "\e[1;36m",
        label: "\e[1;37m",
        value: "\e[32m"
      }

      "#{colors.fetch(name)}#{value}#{colors.fetch(:reset)}"
    end

    def asset_request?(path)
      path.start_with?("/assets/")
    end

    def log_request(request, status, start_time)
      method = request&.method.to_s.empty? ? "GET" : request.method.to_s.upcase
      path = request&.path.to_s.empty? ? "/" : request.path
      line = "#{method} #{path} -> #{color_status(status)} (#{duration_ms(start_time)})"
      line = "\e[2m#{line}\e[0m" if asset_request?(path)

      puts line
    end

    def suppress_io_buffer_experimental_warning
      return unless defined?(IO::Buffer)

      previous = Warning[:experimental]
      Warning[:experimental] = false
      IO::Buffer.new(0)
    ensure
      Warning[:experimental] = previous unless previous.nil?
    end

    def log_startup(port:, source_dir:, assets_dir:, source_label: "watching")
      puts color(:title, "Klenod example server")
      puts "  #{color(:label, "url")}       #{color(:value, "http://localhost:#{port}")}"
      puts "  #{color(:label, source_label)} #{source_dir}"
      puts "  #{color(:label, "assets")}    #{assets_dir || color(:dim, "in memory")}"
    end
  end
end
