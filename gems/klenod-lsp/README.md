# klenod-lsp

Language Server Protocol support for Klenod applications. It uses the configured
Klenod plugins to analyze Haml, Ruby imports, and CSS without evaluating
application code.

## Features

- Diagnostics for Haml, generated Ruby, unresolved imports, unused imports,
  unknown component props, and unknown scoped CSS classes.
- Definition, hover, document links, and completion for imports and Haml
  component tags.
- Import navigation for Ruby and for CSS `@import`, `url()`, and
  `composes ... from` references.
- Find references, document and workspace symbols, and reference-count code
  lenses.
- Symbol rename within a Haml or Ruby file and import-preserving edits when
  files or directories move.
- Prop and slot information for Haml components, including spelling suggestions
  for unknown props.
- Scoped CSS class definition, hover, completion, and validation in Haml.
- Route lenses and hovers when `RouterPlugin` is configured.

Ruby support is intentionally limited to Klenod imports and their bound
constants. Use a Ruby language server alongside Klenod for general Ruby
features.

## Installation

Add the gem to the application Gemfile:

```ruby
gem "klenod-lsp"
```

Install it and start the server from a project containing `klenod.config.rb`:

```sh
bundle install
bundle exec klenod lsp
```

The `klenod` command comes from the `klenod` meta gem. The meta gem does not
install `klenod-lsp` automatically.

Configure the editor to run that command for `.haml` files. Ruby and CSS files
can also use it alongside their usual language servers.

For example, with Neovim:

```lua
vim.api.nvim_create_autocmd("FileType", {
  pattern = "haml",
  callback = function()
    vim.lsp.start({
      name = "klenod",
      cmd = { "bundle", "exec", "klenod", "lsp" },
      root_dir = vim.fs.root(0, { "klenod.config.rb", "Gemfile" }),
    })
  end,
})
```

## Configuration

The CLI has no LSP-specific options. It loads the nearest `klenod.config.rb`
and uses its source directory, plugins, and entrypoints. Position encoding is
negotiated with the editor.

Frameworks that construct their configuration in Ruby can start the server
directly:

```ruby
require "klenod/lsp"

config = MyFramework.build_config(mode: :development)
context = config.context(analysis: true)

exit Klenod::LSP::Server.new(
  context: context,
  entrypoints: config.entrypoints
).start
```

`Server.new` accepts:

- `context:` — a required `Klenod::Build::Context`; use `analysis: true`.
- `entrypoints:` — roots collected in addition to source files; defaults to
  none.
- `input:` and `output:` — the JSON-RPC streams; default to stdin and stdout.
- `logger:` — server logging; defaults to stderr.

The web example has a complete runner at `example/web/bin/lsp`.

## How it works

Open buffers are transformed with the build plugins for immediate diagnostics.
A background graph indexes Ruby, Haml, and CSS files for cross-file features,
including lazy dependencies. Analysis mode skips network fetches, JavaScript
compilation, image generation, and filesystem output.

The editor reports file changes to the server. Clients without dynamic watched
file registration need to configure a watcher for the application source
directory.

## Limitations

- References and rename edits cover application source files. Definition and
  hover can also reach installed gems, while virtual modules have no file
  location.
- Cross-file results can be incomplete while the initial background index is
  still running.
- Documents use full-text synchronization, and completion examines only the
  current line up to the cursor.
