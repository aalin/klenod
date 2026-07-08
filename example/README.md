# Klenod Example

This example exercises the current module graph, plugin pipeline, emitted assets, and watch-mode update events.

Run it from the repository root:

```sh
bundle exec ruby example/run.rb
bundle exec ruby example/build_and_load.rb
bundle exec ruby example/watch.rb
bundle exec ruby example/server.rb
```

`run.rb` loads `src/pages/home.rb`, resolves its `import("../shared")`, evaluates both files as `Klenod::Runtime::Mod` instances, and prints exported constants from the entrypoint.

`build_and_load.rb` writes `example/dist/klenod.bundle`, reloads it through the runtime API, and evaluates the entrypoint without using the build graph.

`watch.rb` keeps the process running and prints invalidation events when loaded files under `example/src` change.

`server.rb` starts a small `async-http` server on `http://localhost:9292`. It watches the source tree, swaps to the latest loaded page after the dependency tree updates, and serves emitted CSS/image assets from the build context.

The server page imports CSS and an image with query-driven variants:

```ruby
Styles = import("../styles/home.css")
SmokedFish = import("./smoked-fish.png?width=320,640&format=png")
```
