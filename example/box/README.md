# `Ruby::Box` example

This example builds two runtime bundles with the same entrypoint and module id
(`main.rb`), then loads each bundle into a separate `Ruby::Box`.

Run it from this directory:

```sh
bundle exec ruby build.rb
RUBY_BOX=1 ruby run.rb
```

The build step writes `dist/alpha.bundle` and `dist/beta.bundle`. The run step
creates two boxes, starts Bundler in the main box, then loads the bundles into
the pre-created boxes.

Avoid `RUBY_BOX=1 ruby -rbundler/setup run.rb` and
`RUBY_BOX=1 bundle exec ruby run.rb` for now. Ruby::Box currently interacts
poorly with Bundler if Bundler is loaded before boxes are created.
