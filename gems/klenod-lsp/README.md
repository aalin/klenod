# klenod-lsp

A [Language Server Protocol](https://microsoft.github.io/language-server-protocol/) server for Klenod applications. It transforms open editor documents with the same plugins as a build and reports the result back to the editor.

Current support covers Haml modules:

- Diagnostics: Haml syntax errors, Ruby syntax errors inside Haml, syntax errors in the generated component Ruby, and unresolved imports with the same "did you mean" suggestions the build prints.
- Go to definition: `import("...")` literals and `%Component` tags jump to the imported file. Component tags are followed through the constant bound in the leading `:ruby` filter, such as `Details = import("/components/Details")`.

The server never evaluates application code. It only transforms and resolves, so unsaved editor text stays out of the module graph.

## Starting the server

Applications configured with `klenod.config.rb` add the gem to their Gemfile and use the `klenod` command. The `klenod` meta gem does not depend on `klenod-lsp`; without it, `klenod lsp` prints what to install.

```ruby
gem "klenod-lsp"
```

```sh
bundle exec klenod lsp
```

Frameworks that build their `Klenod::Build::Config` in Ruby start the same server from their own script. The web example does this in `example/web/bin/lsp`:

```ruby
require "klenod/lsp"

context = Example::WebConfig.build_config(mode: :development).context
exit Klenod::LSP::Server.new(context: context).start
```

`Klenod::LSP::Server.new(context:)` speaks JSON-RPC over stdin and stdout. Anything printed to `$stdout` while the server runs is redirected to stderr so plugin output cannot corrupt the protocol stream. `start` returns the process exit status: `0` after the client sent `shutdown`, `1` otherwise.

## Editor configuration

The server handles documents whose file extension is `.haml` and whose path lies inside the configured source directory. Point your editor's LSP client at the start command and the `haml` file type.

Neovim:

```lua
vim.api.nvim_create_autocmd("FileType", {
  pattern = "haml",
  callback = function()
    vim.lsp.start({
      name = "klenod",
      cmd = { "bin/lsp" }, -- or { "bundle", "exec", "klenod", "lsp" }
      root_dir = vim.fs.root(0, { "klenod.config.rb", "Gemfile" }),
    })
  end,
})
```

Helix (`languages.toml`):

```toml
[language-server.klenod]
command = "bin/lsp"

[[language]]
name = "haml"
language-servers = ["klenod"]
```

Zed (`.zed/settings.json`) can run it through a generic language server extension, and VS Code needs a small client extension or a generic LSP client extension that maps the `haml` language to the command.

## Limitations

- Positions are counted in Ruby characters rather than UTF-16 code units, so ranges on lines containing characters outside the Basic Multilingual Plane can be off by one per such character.
- Documents are synchronized with their full text on every change, and every change is analyzed synchronously.
- Definitions only target modules under the application source directory. `gem://` and virtual modules return no location yet.
- Hover, completion, CSS class navigation, and `.rb` support are not implemented.
