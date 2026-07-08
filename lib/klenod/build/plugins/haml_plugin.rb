# frozen_string_literal: true

require_relative "../../source_map"
require_relative "../plugin"
require_relative "../dependency"
require_relative "../module_id"
require_relative "../transform_result"
require_relative "../watched_pattern"
require_relative "intl_plugin"

module Klenod
  module Build
    module Plugins
      class HamlPlugin < Plugin
        HamlTransformResult = Data.define(:code, :source_map, :metadata)

        DEFAULT_COMPONENT_BASE_CLASS = "Object"
        DEFAULT_DESCRIPTOR_FACTORY = "Object"

        class DefaultTransformer
          def call(
            source:,
            module_id:,
            component_class_name:,
            component_base_class:,
            descriptor_factory:,
            styles_source:,
            translations_source:
          )
            code =
              <<~RUBY
                class #{component_class_name} < #{component_base_class}
                  Translations = #{translations_source}
                  DescriptorFactory = #{descriptor_factory}

                  def render
                #{indent(compile_template(source), 4)}
                  end

                  HtmlString = Class.new(String)

                  def h(tag, *children)
                    attributes = children.last.is_a?(Hash) ? children.pop : {}
                    rendered_attributes =
                      attributes
                        .compact
                        .map { |name, value| %( \#{escape_html(name)}="\#{escape_html(value)}") }
                        .join
                    rendered_children = children.flatten.compact.map { |child| escape_html(child) }.join

                    HtmlString.new("<\#{tag}\#{rendered_attributes}>\#{rendered_children}</\#{tag}>")
                  end

                  def escape_html(value)
                    return value.to_s if value.is_a?(HtmlString)

                    value
                      .to_s
                      .gsub("&", "&amp;")
                      .gsub("<", "&lt;")
                      .gsub(">", "&gt;")
                      .gsub('"', "&quot;")
                  end
                end

                Default = #{component_class_name}
                Styles = #{styles_source}
                Default.const_set(:Styles, Styles)
                Translations = Default::Translations
              RUBY

            HamlTransformResult.new(
              code,
              SourceMap::SourceMap.parse(source, code),
              {source: source, module_id: module_id}
            )
          end

          private

          TemplateNode = Data.define(:type, :line_no, :tag_name, :content, :children)

          def compile_template(source)
            nodes = parse_nodes(source)
            return "nil" if nodes.empty?
            return compile_node(nodes.fetch(0)) if nodes.length == 1

            "[\n#{indent(nodes.map { |node| compile_node(node) }.join(",\n"), 2)}\n].join"
          end

          def parse_nodes(source)
            root = TemplateNode.new(:root, 0, nil, nil, [])
            stack = [[-1, root]]

            source.each_line.with_index(1) do |line, line_no|
              next if line.strip.empty?

              indent = line[/\A */].length
              node = parse_line(line.strip, line_no)

              stack.pop while stack.last.fetch(0) >= indent
              stack.last.fetch(1).children << node
              stack << [indent, node]
            end

            root.children
          end

          def parse_line(line, line_no)
            case line
            when /\A%(?<tag>[A-Za-z][A-Za-z0-9:_-]*)=\s*(?<content>.+)\z/
              TemplateNode.new(:dynamic_tag, line_no, $~[:tag], $~[:content], [])
            when /\A%(?<tag>[A-Za-z][A-Za-z0-9:_-]*)(?:\s+(?<content>.*))?\z/
              TemplateNode.new(:tag, line_no, $~[:tag], $~[:content], [])
            when /\A=\s*(?<content>.+)\z/
              TemplateNode.new(:expression, line_no, nil, $~[:content], [])
            else
              TemplateNode.new(:text, line_no, nil, line, [])
            end
          end

          def compile_node(node)
            mark = source_mark(node)
            expression =
              case node.type
              when :tag
                compile_tag(node)
              when :dynamic_tag
                compile_dynamic_tag(node)
              when :expression
                "(#{node.content})"
              when :text
                node.content.inspect
              end

            "#{mark}\n#{expression}"
          end

          def compile_dynamic_tag(node)
            children = ["(#{node.content})"]
            children.concat(node.children.map { |child| compile_node(child) })

            "h(#{node.tag_name.inspect},\n#{indent(children.join(",\n"), 2)})"
          end

          def compile_tag(node)
            children = []
            children << node.content.inspect if node.content
            children.concat(node.children.map { |child| compile_node(child) })

            if children.empty?
              "h(#{node.tag_name.inspect})"
            else
              "h(#{node.tag_name.inspect},\n#{indent(children.join(",\n"), 2)})"
            end
          end

          def source_mark(node)
            "# #{SourceMap::Mark.new(node.line_no, node.content || node.tag_name)}"
          end

          def indent(value, spaces)
            value.lines.map { |line| "#{" " * spaces}#{line}" }.join
          end
        end

        def initialize(
          component_base_class: DEFAULT_COMPONENT_BASE_CLASS,
          descriptor_factory: DEFAULT_DESCRIPTOR_FACTORY,
          transformer: DefaultTransformer.new
        )
          @component_base_class = component_base_class
          @descriptor_factory = descriptor_factory
          @transformer = transformer
        end

        def transform(module_id, code, context)
          return super unless module_id.extname == ".haml"

          companion_css = companion_path(module_id, ".css")
          dependencies = []
          styles_source = "{}.freeze"

          if context.absolute_path(companion_css).file?
            dependency =
              Dependency
                .create(
                  specifier: "./#{File.basename(companion_css.path)}",
                  importer_id: module_id,
                  kind: :companion_style,
                  metadata: {optional: true}
                )
                .with(id: "#{module_id}:companion_style")
            dependencies << dependency
            styles_source = "__klenod_import__(#{dependency.id.inspect})"
          end
          translations_source = deep_freeze_source(translations_for(context, module_id))
          component_class_name = component_class_name(module_id)
          haml_result =
            @transformer.call(
              source: code,
              module_id: module_id,
              component_class_name: component_class_name,
              component_base_class: @component_base_class,
              descriptor_factory: @descriptor_factory,
              styles_source: styles_source,
              translations_source: translations_source
            )

          TransformResult.new(
            haml_result.code,
            dependencies,
            haml_result.source_map,
            [],
            companion_patterns(module_id),
            haml_result.metadata
          )
        end

        private

        def translations_for(context, module_id)
          intl_plugin = context.plugins.find { |plugin| plugin.respond_to?(:translations_for) }
          intl_plugin ? intl_plugin.translations_for(context, module_id) : {}
        end

        def deep_freeze_source(value)
          case value
          when Hash
            "{#{value.map { |key, child| "#{key.inspect} => #{deep_freeze_source(child)}" }.join(", ")}}.freeze"
          when Array
            "[#{value.map { |child| deep_freeze_source(child) }.join(", ")}].freeze"
          else
            value.inspect
          end
        end

        def component_class_name(module_id)
          basename = File.basename(module_id.path, ".haml")
          classified =
            basename
              .split(/[^A-Za-z0-9]+/)
              .reject(&:empty?)
              .map { |part| part[0].upcase + part[1..] }
              .join

          classified.empty? ? "Component" : classified
        end

        def companion_patterns(module_id)
          base = module_id.path.delete_suffix(".haml")

          [
            WatchedPattern.new(module_id, "#{base}.css", :companion_style, {}),
            WatchedPattern.new(module_id, "#{base}.intl.*.toml", :companion_intl, {})
          ]
        end

        def companion_path(module_id, extname)
          ModuleId.new(module_id.path.delete_suffix(".haml") + extname, nil)
        end
      end
    end
  end
end
