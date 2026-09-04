# klenod-test

`klenod-test` discovers and runs application tests without choosing a test
framework. Add its plugin to the application's build configuration:

```ruby
plugins [
  Klenod::Test::Plugin.new,
  Klenod::Build::Plugins::RubyPlugin.new
]
```

The plugin finds `*.test.rb` files in deterministic order and prevents
application modules and other tests from importing them. Tests can import normal
application modules. `Klenod::Test::Suite` indexes each test's eager and lazy
dependency closure without evaluating application code.

The runner can run the full suite once or watch the module graph and rerun only
tests related to a change. Install the `klenod` meta-gem and run it from an
application directory:

```sh
bundle exec klenod test --run
bundle exec klenod test --watch
```

Without an option, the command watches unless `CI` is set.

The command searches the current directory and its parents for
`klenod.test.rb`. The file supplies the application-specific context and test
framework adapter:

```ruby
context do
  path = File.expand_path("klenod.config.rb", __dir__)
  Klenod::Build::ConfigLoader.load(path).context
end

execute do |context, test_paths|
  # Register and run the selected test modules, then return an exit status.
end

format_error do |error, context|
  # Optionally format collection or evaluation errors.
end
```

The runner does not choose a testing framework. Applications provide a context
factory and an execution callback. The same runner is also available as a Ruby
API:

```ruby
runner = Klenod::Test::Runner.new(
  context: -> { build_config.context },
  execute: ->(context, test_paths) { run_tests(context, test_paths) },
  watch: true
)

exit runner.call
```

Each batch runs in a fresh worker process. The execution callback receives that
worker's context and sorted source-relative test paths, then returns an integer
exit status.

## Coverage

Run the complete test suite once under Covered:

```sh
bundle exec klenod coverage
bundle exec klenod coverage --report partial --minimum 90
```

Coverage defaults to the brief report with no required minimum. Configure both
defaults in `klenod.test.rb`:

```ruby
coverage report: :brief, minimum: 90
```

Command-line values override the configuration. Reports may be `brief`,
`partial`, `full`, `markdown`, or `quiet`. The minimum is an overall percentage
from 0 through 100; falling below it returns a failing status.

Coverage includes evaluated application Ruby and source-mapped modules. Klenod
maps generated execution lines back to the original Haml, Markdown, or other
plugin source. It excludes test modules, gem and virtual modules, and generated
wrappers for data files. Source files which no test evaluates are not synthesized
into the report.

Collection wraps the application's existing `execute` callback, so it does not
depend on Minitest, RSpec, or another test framework. Frameworks that start
independent subprocesses need their own subprocess coverage integration.
