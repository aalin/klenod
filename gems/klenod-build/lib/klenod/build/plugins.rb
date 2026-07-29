# frozen_string_literal: true

module Klenod
  module Build
    module Plugins
      autoload :Ruby, File.expand_path("plugins/ruby", __dir__)
      autoload :RubyPlugin, File.expand_path("plugins/ruby", __dir__)
      autoload :Intl, File.expand_path("plugins/intl", __dir__)
      autoload :IntlPlugin, File.expand_path("plugins/intl", __dir__)
      autoload :Haml, File.expand_path("plugins/haml", __dir__)
      autoload :HamlPlugin, File.expand_path("plugins/haml", __dir__)
      autoload :Markdown, File.expand_path("plugins/markdown", __dir__)
      autoload :MarkdownPlugin, File.expand_path("plugins/markdown", __dir__)
      autoload :Css, File.expand_path("plugins/css", __dir__)
      autoload :CssPlugin, File.expand_path("plugins/css", __dir__)
      autoload :GoogleFonts, File.expand_path("plugins/google_fonts", __dir__)
      autoload :GoogleFontsPlugin, File.expand_path("plugins/google_fonts", __dir__)
      autoload :Svg, File.expand_path("plugins/svg", __dir__)
      autoload :SvgPlugin, File.expand_path("plugins/svg", __dir__)
      autoload :Image, File.expand_path("plugins/image", __dir__)
      autoload :ImagePlugin, File.expand_path("plugins/image", __dir__)
      autoload :Data, File.expand_path("plugins/data", __dir__)
      autoload :DataPlugin, File.expand_path("plugins/data", __dir__)
      autoload :JsonPlugin, File.expand_path("plugins/data", __dir__)
      autoload :YamlPlugin, File.expand_path("plugins/data", __dir__)
      autoload :TomlPlugin, File.expand_path("plugins/data", __dir__)
      autoload :TextPlugin, File.expand_path("plugins/data", __dir__)
      autoload :Router, File.expand_path("plugins/router", __dir__)
      autoload :RouterPlugin, File.expand_path("plugins/router", __dir__)
    end
  end
end
