# klenod-test

`klenod-test` runs application tests discovered by Klenod's `TestPlugin`. It can
run the full suite once or watch the module graph and rerun only tests related to
a change. Install the `klenod` meta-gem and run it from an application directory:

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
