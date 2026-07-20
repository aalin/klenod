# frozen_string_literal: true

require "fileutils"

module KlenodPerformance
  CaseDefinition = Data.define(:name, :component_count, :route_count) do
    def initialize(name:, component_count:, route_count: nil)
      super(
        name: name,
        component_count: Integer(component_count),
        route_count: route_count ? Integer(route_count) : [Integer(component_count) / 10, 10].max
      )
    end
  end

  class Generator
    WEB_1K_CASE = CaseDefinition.new(name: "web-1k", component_count: 1000)
    WEB_5K_CASE = CaseDefinition.new(name: "web-5k", component_count: 5000)
    DEFAULT_CASE = WEB_1K_CASE

    def initialize(root_dir:)
      @root_dir = File.expand_path(root_dir)
    end

    def generate(case_definition = DEFAULT_CASE)
      case_dir = File.join(@root_dir, "cases", case_definition.name)
      FileUtils.rm_rf(case_dir)
      FileUtils.mkdir_p(case_dir)

      write_framework(case_dir)
      write_config(case_dir)
      write_server(case_dir)
      write_layouts(case_dir)
      write_components(case_dir, case_definition.component_count)
      write_pages(case_dir, case_definition)
      write_asset(case_dir)
      write_manifest(case_dir, case_definition)

      case_dir
    end

    private

    def write_file(path, content)
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, content)
    end

    def write_framework(case_dir)
      write_file(
        File.join(case_dir, "lib/framework.rb"),
        <<~RUBY
          # frozen_string_literal: true

          require "cgi/escape"

          module Example
            class Component
              def initialize(**props)
                props.each { |name, value| instance_variable_set("@\#{name}", value) }
              end
            end

            module H
              HtmlString = Class.new(String)
              VOID_TAGS = %i[area base br col embed hr img input link meta param source track wbr].freeze

              def self.[](tag, *children, **props)
                return tag.new(**props).render if tag.is_a?(Class)

                attributes =
                  props
                    .compact
                    .reject { |_name, value| value == false }
                    .map { |name, value| rendered_attribute(name, value) }
                    .join

                return HtmlString.new("<\#{tag}\#{attributes}>") if VOID_TAGS.include?(tag)

                rendered_children = children.flatten.compact.map { |child| escape_html(child) }.join
                HtmlString.new("<\#{tag}\#{attributes}>\#{rendered_children}</\#{tag}>")
              end

              def self.escape_html(value)
                return value.to_s if value.is_a?(HtmlString)

                CGI.escapeHTML(value.to_s)
              end

              def self.rendered_attribute(name, value)
                return " \#{escape_html(name)}" if value == true

                %( \#{escape_html(name)}="\#{escape_html(value)}")
              end
            end
          end
        RUBY
      )
    end

    def write_config(case_dir)
      write_file(
        File.join(case_dir, "klenod.config.rb"),
        <<~RUBY
          # frozen_string_literal: true

          require_relative "lib/framework"
          require "klenod"

          source_dir "src"
          entrypoint "pages/server"
          output "dist/klenod.bundle"
          assets_dir "dist/public"

          plugins [
            Klenod::Build::Plugins::RouterPlugin.new,
            Klenod::Build::Plugins::RubyPlugin.new,
            Klenod::Build::Plugins::HamlPlugin.new(
              component_base_class: "Example::Component",
              factory: "Example::H"
            ),
            Klenod::Build::Plugins::CssPlugin.new,
            Klenod::Build::Plugins::SvgPlugin.new,
            Klenod::Build::Plugins::JsonPlugin.new,
            Klenod::Build::Plugins::TextPlugin.new
          ]
        RUBY
      )
    end

    def write_server(case_dir)
      write_file(
        File.join(case_dir, "src/pages/server.rb"),
        <<~RUBY
          # frozen_string_literal: true

          Router = import("virtual:router")

          def self.call(path = "/")
            match = Router::Default.match(path)
            match&.route&.path
          end
        RUBY
      )
    end

    def write_layouts(case_dir)
      write_file(
        File.join(case_dir, "src/pages/layout.haml"),
        <<~HAML
          :ruby
            def initialize(children: [])
              @children = children
            end

          %body
            %main.shell
              = @children
        HAML
      )
      write_file(
        File.join(case_dir, "src/pages/layout.css"),
        <<~CSS
          body {
            margin: 0;
            font-family: system-ui, sans-serif;
          }

          .shell {
            display: grid;
            gap: 1rem;
            padding: 2rem;
          }
        CSS
      )
      write_file(
        File.join(case_dir, "src/pages/not-found.haml"),
        <<~HAML
          %article
            %h1 Not found
        HAML
      )
      write_file(
        File.join(case_dir, "src/pages/error.haml"),
        <<~HAML
          %article
            %h1 Error
        HAML
      )
    end

    def write_components(case_dir, count)
      (1..count).each do |index|
        write_component(case_dir, index)
      end
    end

    def write_component(case_dir, index)
      child_index = ((index - 1) / 10) * 10
      child_import =
        if child_index.positive? && index != child_index + 1
          "  Child = import(\"/#{component_path(index - 1, ext: ".haml")}\")\n"
        else
          ""
        end

      write_file(
        File.join(case_dir, "src", component_path(index, ext: ".haml")),
        <<~HAML
          :ruby
          #{child_import}  def initialize(label: "Component #{component_number(index)}", value: #{index}, children: [])
              @label = label
              @value = value
              @children = children
            end

          %section.card
            %h2= @label
            %p= "Value \#{@value}"
            = if defined?(Child)
              %Child{ label: "\#{@label} child", value: @value - 1 }
            = @children
        HAML
      )
      write_file(
        File.join(case_dir, "src", component_path(index, ext: ".css")),
        <<~CSS
          .card {
            display: grid;
            gap: 0.375rem;
            border: 1px solid hsl(#{index % 360} 40% 72%);
            padding: 0.75rem;
          }

          h2 {
            margin: 0;
            font-size: 1rem;
          }
        CSS
      )
    end

    def write_pages(case_dir, case_definition)
      route_count = case_definition.route_count
      components_per_route = (case_definition.component_count.to_f / route_count).ceil

      write_page(case_dir, "page.haml", 1, [1, components_per_route].max)

      route_count.times do |route_index|
        first_component = (route_index * components_per_route) + 1
        next if first_component > case_definition.component_count

        last_component = [first_component + components_per_route - 1, case_definition.component_count].min
        path = route_path(route_index + 1)
        write_page(case_dir, path, first_component, last_component)
      end
    end

    def write_page(case_dir, relative_path, first_component, last_component)
      imports =
        (first_component..last_component).map do |index|
          "  Component#{component_number(index)} = import(\"/#{component_path(index, ext: ".haml")}\")"
        end.join("\n")
      renders =
        (first_component..last_component).map do |index|
          "  %Component#{component_number(index)}{ label: \"Component #{component_number(index)}\", value: #{index} }"
        end.join("\n")

      write_file(
        File.join(case_dir, "src/pages", relative_path),
        <<~HAML
          :ruby
          #{imports}

          %article
            %h1 Performance route #{relative_path}
          #{renders}
        HAML
      )
    end

    def write_asset(case_dir)
      write_file(
        File.join(case_dir, "src/components/logo.svg"),
        <<~SVG
          <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 32 32" width="32" height="32">
            <rect width="32" height="32" rx="6" fill="#991b1b"/>
            <path d="M8 16h16M16 8v16" stroke="#fff7ed" stroke-width="4" stroke-linecap="round"/>
          </svg>
        SVG
      )
    end

    def write_manifest(case_dir, case_definition)
      write_file(
        File.join(case_dir, "case.txt"),
        <<~TEXT
          name=#{case_definition.name}
          components=#{case_definition.component_count}
          routes=#{case_definition.route_count}
        TEXT
      )
    end

    def component_number(index)
      format("%04d", index)
    end

    def component_path(index, ext:)
      File.join(
        "components",
        "cluster-#{format("%02d", (index - 1) / 250)}",
        "group-#{format("%02d", (index - 1) / 25)}",
        "Component#{component_number(index)}#{ext}"
      )
    end

    def route_number(index)
      format("%03d", index)
    end

    def route_path(index)
      File.join(
        "bench",
        "section-#{format("%02d", (index - 1) / 25)}",
        "group-#{format("%02d", (index - 1) / 5)}",
        "route-#{route_number(index)}",
        "page.haml"
      )
    end
  end
end
