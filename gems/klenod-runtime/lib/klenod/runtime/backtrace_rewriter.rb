# frozen_string_literal: true

#
# Copyright Andrés Alin <andreas.alin@gmail.com>
# License: AGPL-3.0

module Klenod
  module Runtime
    class BacktraceRewriter
      class BacktraceString < String
        attr_reader :parsed_backtrace_entry

        def initialize(entry)
          super(entry.to_s)
          @parsed_backtrace_entry = entry
        end
      end

      ParsedBacktraceEntry =
        Data.define(:file, :line, :description) do
          def self.parse(line)
            case line
            in BacktraceString
              line.parsed_backtrace_entry
            in /\A(?<file>.*):(?<line>\d+):in '(?<description>.*)'\z/
              new($~[:file], $~[:line].to_i, $~[:description])
            else
              nil
            end
          end

          def to_s
            "#{file}:#{line}:in '#{description}'"
          end

          def to_backtrace_string
            BacktraceString.new(self)
          end
        end

      def initialize(mods)
        @source_maps = source_maps_for(mods)
        @source_map_cache = Hash.new { |h, path| h[path] = @source_maps[path] }
        @constant_display_names = constant_display_names_for(mods)
      end

      def rewrite_exception(e)
        rewrite_exception_message(e)
        e.set_backtrace(rewrite_backtrace(e.backtrace))
      end

      def rewrite_backtrace(backtrace)
        backtrace.map do |line|
          if (entry = ParsedBacktraceEntry.parse(line))
            rewrite_backtrace_entry(entry).to_backtrace_string
          else
            line
          end
        end
      end

      # The original source of the module evaluated from `file`, for tools
      # that show an excerpt next to a frame.
      def source_for(file)
        @source_map_cache[file]&.input
      end

      private

      def source_maps_for(mods)
        mods.each_with_object({}) do |(key, mod), index|
          next unless mod.respond_to?(:source_map)

          source_map = mod.source_map
          next unless source_map

          index[key.to_s] = source_map
          index[mod.path.to_s] = source_map if mod.respond_to?(:path)
          index[mod.eval_path.to_s] = source_map if mod.respond_to?(:eval_path)
        end
      end

      def rewrite_backtrace_entry(entry)
        if (original_line_no = find_original_line_no(entry.file, entry.line))
          entry.with(line: original_line_no, description: rewrite_const_paths(entry.description))
        else
          entry.with(description: rewrite_const_paths(entry.description))
        end
      end

      def constant_display_names_for(mods)
        mods.each_with_object({}) do |(key, mod), index|
          next unless mod.respond_to?(:constant_name)

          display_path = mod.respond_to?(:path) ? mod.path : key
          display_name = "Mod[#{display_path.inspect}]"
          index["Klenod::Runtime::Generated::#{mod.constant_name}"] = display_name
          index[mod.constant_name] = display_name
        end
      end

      def rewrite_const_paths(value)
        @constant_display_names.reduce(value.to_s) do |message, (generated_name, display_name)|
          message.gsub(generated_name, display_name)
        end
      end

      def rewrite_exception_message(error)
        message = rewrite_const_paths(error.message)
        return if message == error.message

        error.define_singleton_method(:message) { message }
        error.define_singleton_method(:to_s) { message }
      end

      def find_original_line_no(file, line_no)
        @source_map_cache[file]&.find_original_line_no(line_no)
      end
    end
  end
end
