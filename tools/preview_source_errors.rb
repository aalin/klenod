# frozen_string_literal: true

# Prints the terminal report for a set of broken source files, so changes to
# error formatting can be checked by eye.
#
#   bundle exec ruby tools/preview_source_errors.rb [filter]
#
# The optional filter keeps only samples whose file name includes it.

require "fileutils"
require "tmpdir"

require "klenod/build"
require "klenod/plugin/css"
require "klenod/plugin/javascript"

module SourceErrorPreview
  SAMPLES = {
    "haml/InvalidAttributes.haml" => <<~HAML,
      .hero
        %img.mascot(src="/logo.png" alt="Logo")
        %AnimatedNumber(value=delta(:count) format="signed")
        .text
          .wordmark mayu
    HAML
    "haml/AmbiguousAttributes.haml" => <<~HAML,
      %p Before
      %a(value=count + 1)
      %p After
    HAML
    "haml/RubyFilter.haml" => <<~HAML,
      :ruby
        def initialize
          @count = 0

      %p Count: \#{@count}
    HAML
    "haml/SilentScript.haml" => <<~HAML,
      %p Before
      - raise "foo'
      %p After
    HAML
    "data/config.json" => <<~JSON,
      {
        "name": "Klenod",
        "version": 1,,
        "tags": []
      }
    JSON
    "data/config.yaml" => <<~YAML,
      name: Klenod
      tags:
        - one
       - two
    YAML
    "data/config.toml" => <<~TOML,
      name = "Klenod"
      version = = 1
    TOML
    "styles/Card.css" => <<~CSS,
      .card {
        color: red;
        --gap: );
      }
    CSS
    "scripts/Thing.tsx" => <<~TSX,
      export function Thing() {
        const count: number = 1
        return <div>{count</div>
      }
    TSX
    "ruby/MissingImport.rb" => <<~RUBY
      Card = import("./Crad")
    RUBY
  }.freeze

  EXTRA_FILES = {
    "ruby/Card.rb" => "Default = 1\n"
  }.freeze

  module_function

  def run(filter)
    samples = SAMPLES.select { |path, _source| filter.nil? || path.include?(filter) }
    abort "No samples match #{filter.inspect}" if samples.empty?

    Dir.mktmpdir("klenod-errors") do |dir|
      SAMPLES.merge(EXTRA_FILES).each do |path, source|
        full_path = File.join(dir, path)
        FileUtils.mkdir_p(File.dirname(full_path))
        File.write(full_path, source)
      end

      samples.each_key do |path|
        puts "\e[2m#{"─" * 20} #{path} #{"─" * 20}\e[0m"
        puts report_for(dir, path)
        puts
      end
    end
  end

  def report_for(dir, path)
    context =
      Klenod::Build::Context.new(
        source_dir: dir,
        plugins: [
          *Klenod::Build::Context.default_plugins,
          Klenod::Build::Plugins::CSSPlugin.new,
          Klenod::Build::Plugins::JavaScriptPlugin.new
        ]
      )
    context.collect(path)
    "(no error)"
  rescue => error
    "#{error.message}\n\n\e[2m(#{error.class})\e[0m"
  end
end

SourceErrorPreview.run(ARGV.first) if $PROGRAM_NAME == __FILE__
