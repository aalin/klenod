# frozen_string_literal: true

module Klenod
  module Build
    module Plugins
      autoload :RubyPlugin, File.expand_path("plugins/ruby_plugin", __dir__)
      autoload :IntlPlugin, File.expand_path("plugins/intl_plugin", __dir__)
      autoload :HamlPlugin, File.expand_path("plugins/haml_plugin", __dir__)
      autoload :MarkdownPlugin, File.expand_path("plugins/markdown_plugin", __dir__)
      autoload :CssPlugin, File.expand_path("plugins/css_plugin", __dir__)
      autoload :GoogleFontsPlugin, File.expand_path("plugins/google_fonts_plugin", __dir__)
      autoload :SvgPlugin, File.expand_path("plugins/svg_plugin", __dir__)
      autoload :ImagePlugin, File.expand_path("plugins/image_plugin", __dir__)
      autoload :DataPlugin, File.expand_path("plugins/data_plugin", __dir__)
      autoload :JsonPlugin, File.expand_path("plugins/data_plugin", __dir__)
      autoload :YamlPlugin, File.expand_path("plugins/data_plugin", __dir__)
      autoload :TomlPlugin, File.expand_path("plugins/data_plugin", __dir__)
      autoload :TextPlugin, File.expand_path("plugins/data_plugin", __dir__)
      autoload :RouterPlugin, File.expand_path("plugins/router_plugin", __dir__)
    end
  end
end
