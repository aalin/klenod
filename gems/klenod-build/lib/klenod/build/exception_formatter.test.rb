# frozen_string_literal: true

require "minitest/autorun"

require "klenod/runtime/source_map"
require_relative "exception_formatter"

class Klenod::Build::ExceptionFormatter::Test < Minitest::Test
  ExceptionFormatter = Klenod::Build::ExceptionFormatter
  SourceExcerpt = Klenod::Build::SourceExcerpt
  SourceMap = Klenod::Runtime::SourceMap

  FakeMod = Data.define(:source_map, :path, :eval_path, :constant_name)

  SOURCE = <<~HAML
    :ruby
      def hello
        raise "asd"
      end
    %div
      %p= hello
  HAML

  GENERATED = <<~RUBY
    class MyComponent
      # #{SourceMap::Mark[2]}
      def hello
        # #{SourceMap::Mark[3]}
        raise "asd"
      end
      def render
        H[:div,
          H[:p
            # #{SourceMap::Mark[6]}
            hello
          ]
        ]
      end
    end
  RUBY

  def test_reports_the_error_with_an_excerpt_of_the_first_frame_with_source
    error = raised(
      "Something went wrong",
      "/app/components/MyComponent.haml:5:in 'hello'",
      "/app/components/MyComponent.haml:11:in 'render'",
      "/gems/rack/lib/rack.rb:12:in 'call'"
    )

    formatted = ExceptionFormatter.format(error, mods: {"app:/components/MyComponent.haml" => component}, ansi: false)

    assert_equal(<<~TEXT.chomp, formatted)
      × RuntimeError: Something went wrong

          ╭─[app:/components/MyComponent.haml:3]
        1 │ :ruby
        2 │   def hello
      > 3 │     raise "asd"
        4 │   end
        5 │ %div
          ╰────
        at app:/components/MyComponent.haml:3:in 'hello'
        at app:/components/MyComponent.haml:6:in 'render'
        at /gems/rack/lib/rack.rb:12:in 'call'
    TEXT
  end

  def test_dims_frames_outside_the_graph
    error = raised("Boom", "/app/components/MyComponent.haml:5:in 'hello'", "/gems/rack/lib/rack.rb:12:in 'call'")

    formatted = ExceptionFormatter.format(error, mods: {"app:/components/MyComponent.haml" => component}, ansi: true, links: false)

    assert_includes(formatted, "\e[2mat\e[0m \e[34mapp:\e[1m/components/MyComponent.haml\e[22m:3\e[0m\e[2m:in 'hello'\e[0m")
    assert_includes(formatted, "\e[2mat /gems/rack/lib/rack.rb:12:in 'call'\e[0m")
  end

  def test_rewrites_generated_constant_paths
    constant_name = "Mod_101b82598ea9cbb7174d556e"
    error = NameError.new("undefined local variable or method 'x' for an instance of Klenod::Runtime::Generated::#{constant_name}::Exports::Page")
    error.set_backtrace(["/app/routes/page.haml:4:in 'Klenod::Runtime::Generated::#{constant_name}::Exports::Page#render'"])
    mod = FakeMod.new(nil, "app:/routes/page.haml", "/app/routes/page.haml", constant_name)

    formatted = ExceptionFormatter.format(error, mods: {"app:/routes/page.haml" => mod}, ansi: false)

    assert_includes(formatted, "for an instance of Mod[\"app:/routes/page.haml\"]::Exports::Page")
    assert_includes(formatted, "at app:/routes/page.haml:4:in 'Mod[\"app:/routes/page.haml\"]::Exports::Page#render'")
    refute_includes(formatted, "Klenod::Runtime::Generated")
  end

  def test_keeps_frames_it_cannot_parse
    formatted = ExceptionFormatter.format(raised("Haml parse error", "(haml):21"), ansi: false)

    assert_equal("× RuntimeError: Haml parse error\n\n  at (haml):21", formatted)
  end

  def test_skips_the_excerpt_when_the_line_is_past_the_end_of_the_source
    source_map = SourceMap::SourceMap.parse("raise \"boom\"\n", "# #{SourceMap::Mark[3]}\nraise \"boom\"\n")
    mod = FakeMod.new(source_map, "app:/page.haml", "/app/page.haml", "Mod_000000000000000000000000")

    formatted = ExceptionFormatter.format(raised("Boom", "/app/page.haml:2:in 'render'"), mods: {"app:/page.haml" => mod}, ansi: false)

    assert_equal("× RuntimeError: Boom\n\n  at app:/page.haml:3:in 'render'", formatted)
  end

  def test_links_graph_frames_to_the_files_they_were_evaluated_from
    mod = FakeMod.new(nil, "app:/page.rb", __FILE__, "Mod_000000000000000000000000")

    formatted = ExceptionFormatter.format(raised("Boom", "#{__FILE__}:2:in 'render'"), mods: {"app:/page.rb" => mod}, ansi: true, links: true)

    assert_includes(formatted, "\e]8;;file://#{__FILE__}#2\e\\")
    assert_equal("× RuntimeError: Boom\n\n  at app:/page.rb:2:in 'render'", SourceExcerpt.strip(formatted))
  end

  private

  def component
    FakeMod.new(SourceMap::SourceMap.parse(SOURCE, GENERATED), "app:/components/MyComponent.haml", "/app/components/MyComponent.haml", "Mod_000000000000000000000000")
  end

  def raised(message, *backtrace)
    RuntimeError.new(message).tap { it.set_backtrace(backtrace) }
  end
end
