# Writing Plugins

A Klenod plugin adds behavior to the module graph. A plugin can resolve imports, load source, transform modules, and emit assets.

Plugins run during graph collection and module evaluation. Read [Graph and Plugin Phases](graph-and-plugin-phases.md) for an explanation of these phases.

## Create a Plugin

This example adds support for `.message` files. Each file becomes a Ruby module with a `TEXT` constant.

Create `plugins/message_plugin.rb`:

```ruby
# frozen_string_literal: true

require "klenod/build"

class MessagePlugin < Klenod::Build::Plugin
  def transform(module_id, code, _context)
    return super unless module_id.extname == ".message"

    source = "TEXT = #{code.chomp.inspect}.freeze\n"

    Klenod::Build::TransformResult.new(
      source,
      [],
      nil,
      [],
      [],
      {}
    )
  end
end
```

The call to `super` returns an identity transform. Use it when the plugin does not handle a module.

Add the plugin to `klenod.config.rb`:

```ruby
require_relative "plugins/message_plugin"

plugins [
  MessagePlugin.new,
  *Klenod::Build::Context.default_plugins
]
```

Plugin order is significant. Put a plugin first when it must resolve, load, or transform a module before another plugin.

Create `src/welcome.message`:

```text
Hello from Klenod
```

Import the file from a Ruby module:

```ruby
Message = import("./welcome.message")

puts Message::TEXT
```

Klenod resolves the file and sends its source through each transform hook. The message plugin returns Ruby source for the runtime module.

## Plugin Hooks

All plugins inherit from `Klenod::Build::Plugin`. Override only the hooks that your plugin needs.

| Hook | Purpose | Result |
| --- | --- | --- |
| `resolve(dependency, context)` | Resolve an import specifier. | Return a `ResolvedDependency` or `nil`. |
| `load(module_id, context)` | Supply source for a module. | Return a `String`, a `LoadResult`, or `nil`. |
| `transform(module_id, code, context)` | Transform source and collect module data. | Return a `TransformResult`. |
| `finalize(module_id, result, resolved_dependencies, dependency_records, context)` | Use records from eager dependencies. | Return a `TransformResult`. |
| `import_value(resolved_dependency, record, context)` | Supply the development import value. | Return a Ruby value or `nil`. |
| `runtime_import_value(resolved_dependency, record, context)` | Supply the production import value. | Return serializable data, an instruction, or `nil`. |
| `invalidate_module_ids(paths, context)` | Add modules to a development update. | Return an array of module IDs. |

Klenod calls `resolve` and `load` in plugin order. It stops when a plugin returns a non-`nil` result.

Klenod calls every `transform` and `finalize` hook in plugin order. Each transform receives the source from the previous transform.

Klenod also calls import hooks in plugin order. It stops when a plugin returns a non-`nil` value.

The `context` argument is the active `Klenod::Build::Graph`. It gives plugins access to the source root, records, and asset queue.

Collection hooks must not evaluate application modules. These hooks are `resolve`, `load`, `transform`, and `finalize`.

## Resolve Filesystem Modules

Use `FilesystemResolver` when a plugin owns files in a directory:

```ruby
@resolver = Klenod::Build::FilesystemResolver.new(
  root: import_root,
  extensions: [".rb", ".haml"],
  path_prefix: "gem://message/"
)

path = @resolver.resolve(module_id.relative_path)
```

The resolver checks path case on all operating systems. It raises `ResolveError` for an incorrect or missing path.

The error can contain three suggested filenames. Set `path_prefix` to show canonical module IDs in these suggestions.

The plugin must supply its extension order. The resolver does not infer extensions from the importing module.

## Transform Results

`TransformResult` contains the result of one transform:

| Field | Purpose |
| --- | --- |
| `code` | Contains the source for the next transform and the runtime module. |
| `dependencies` | Contains imports that Klenod must add to the graph. |
| `source_map` | Maps the generated Ruby source to the original source. |
| `assets` | Contains the assets that this module emits. |
| `watched_patterns` | Contains source patterns that invalidate this module. |
| `metadata` | Contains plugin data for later hooks. |

Klenod joins dependencies, assets, and watched patterns from all transforms. Later metadata replaces earlier metadata with the same key.

The last non-`nil` source map becomes the module source map. The `code` field always comes from the last transform.

Use `TransformResult.identity(code)` when a plugin must return the input without changes.

## Virtual Modules

A virtual module has generated source and no source file. Use a `virtual:` module ID for a stable plugin-owned module.

This plugin supplies build information:

```ruby
class BuildInfoPlugin < Klenod::Build::Plugin
  SPECIFIER = "virtual:message/build_info"
  MODULE_ID = Klenod::Build::ModuleId.new("virtual:message/build_info.rb")

  def initialize(version:)
    @version = version
  end

  def resolve(dependency, _context)
    return nil unless dependency.specifier == SPECIFIER

    Klenod::Build::ResolvedDependency.new(
      dependency,
      MODULE_ID,
      {virtual: true}
    )
  end

  def load(module_id, _context)
    return nil unless module_id == MODULE_ID

    "VERSION = #{@version.inspect}.freeze\n"
  end
end
```

Application code can import the module by its public specifier:

```ruby
BuildInfo = import("virtual:message/build_info")

puts BuildInfo::VERSION
```

The `resolve` hook maps the public specifier to one canonical module ID. The `load` hook supplies the source for that ID.

Use a unique prefix for public virtual specifiers. This convention prevents conflicts with virtual modules from other plugins.

### Transform-Generated Modules

A transform can create virtual modules from parts of another source file. Register these modules on the graph context.

```ruby
context.unregister_virtual_modules(module_id)

virtual_id = Klenod::Build::ModuleId.new(
  "virtual:message/generated/#{module_id.relative_path}.rb"
)

context.register_virtual_module(
  virtual_id,
  "VALUE = 42\n",
  owner_id: module_id,
  metadata: {generated_by: :example}
)

dependency =
  Klenod::Build::Dependency
    .create(
      specifier: virtual_id.to_s,
      importer_id: module_id,
      kind: :generated_module,
      metadata: {virtual_module_id: virtual_id}
    )
    .with(id: "#{module_id}:generated_module")
```

Add the dependency to the transform result. Klenod then collects the registered source as a normal module.

Set `owner_id` when the generated module belongs to a transformed module. Remove old owned modules before you register replacements.

Use `virtual_module_metadata(module_id)` when another hook needs the metadata from registration.

## Dependencies and Finalization

A transform must record each import that it adds to generated source. Create a `Dependency` and give it a stable ID.

```ruby
dependency =
  Klenod::Build::Dependency
    .create(
      specifier: "./settings.json",
      importer_id: module_id,
      kind: :message_settings
    )
    .with(id: "#{module_id}:message_settings")
```

`Dependency.create` creates an eager dependency. Klenod resolves and collects eager dependencies before it calls `finalize`.

Set `loc` to a `SourceLocation` when the plugin knows the import position:

```ruby
loc = Klenod::Build::SourceLocation.new(module_id.to_s, line, column)
```

Line and column numbers start at 1. Klenod uses this location in module resolution errors.

Set `eager: false` when generated source uses `__klenod_lazy_import__`. The runtime then defers the import until application code calls it.

Use `finalize` when generated output needs information from dependency records. Examples include class names, asset paths, and dependency metadata.

The `resolved_dependencies` array keeps the resolved module IDs. The `dependency_records` hash maps dependency IDs to collected `ModuleRecord` objects.

Use `dependency.id` in generated calls to `__klenod_import__`. Do not use the source specifier as an internal import key.

## Import Values

The default import value is the target module's `Exports` module. A plugin can supply a different value.

For example, a generated module can export a `Default` value:

```ruby
Default = "Hello".freeze
```

Return that value from `import_value` during development:

```ruby
def import_value(_resolved_dependency, record, context)
  return nil unless record.id.extname == ".message"

  context.mods.fetch(record.id).const_get(:Exports)::Default
end
```

Build mode does not evaluate application modules. Return a runtime instruction from `runtime_import_value`:

```ruby
def runtime_import_value(_resolved_dependency, record, _context)
  return nil unless record.id.extname == ".message"

  Klenod::Runtime::DefaultImport.new(:Default)
end
```

The production runtime uses this instruction to evaluate the target module. It then returns `Exports::Default` to the importer.

A plugin can return plain serializable data from `runtime_import_value`. Store this data in transform metadata during collection.

Do not call `import_value` from `runtime_import_value`. Bundle serialization must not depend on evaluated application exports.

## Assets

A plugin emits assets through the `assets` field of `TransformResult`. Each asset has a logical name and a public output path.

This example emits text from a transform:

```ruby
bytes = "Generated content\n"
hash = Klenod::Build::Hashing.short(bytes)

asset = Klenod::Build::Asset.new(
  "generated/report.txt",
  hash,
  "/assets/report.#{hash}.txt",
  nil,
  bytes,
  "text/plain",
  {type: :report}
)
```

Add the asset to the transform result:

```ruby
Klenod::Build::TransformResult.new(
  generated_code,
  dependencies,
  source_map,
  [asset],
  watched_patterns,
  metadata
)
```

Use `Asset.generated` when asset generation is expensive. Supply `context.asset_generation_queue` to limit concurrent work.

```ruby
asset = Klenod::Build::Asset.generated(
  "generated/report.txt",
  hash,
  "/assets/report.#{hash}.txt",
  nil,
  "text/plain",
  {type: :report},
  queue: context.asset_generation_queue,
  queue_kind: :cpu
) do
  generate_report
end
```

Use `queue_kind: :cpu` for CPU work. Use `queue_kind: :io` for downloads and other IO work.

Calculate the content hash from all generator inputs. A changed input must create a different output path.

Generated asset work can run later. Klenod waits for pending assets before it writes a production build.

## Development Invalidation

Add a `WatchedPattern` when a module depends on files that do not exist in its dependency list.

```ruby
pattern = Klenod::Build::WatchedPattern.new(
  module_id,
  "messages/**/*.locale.yml",
  :message_locale,
  {}
)
```

Add the pattern to `TransformResult#watched_patterns`. A file event that matches the pattern invalidates the owner module.

Use `invalidate_module_ids` when a glob cannot describe the relationship. The hook receives the changed and removed source paths.

```ruby
def invalidate_module_ids(paths, context)
  return [] unless paths.any? { |path| File.basename(path) == "messages.config.rb" }

  context.records.keys.select { |module_id| module_id.extname == ".message" }
end
```

Return canonical `ModuleId` objects that belong to the graph. Klenod also invalidates their dependent modules.

## Load Results and Source Maps

The `load` hook can return a `LoadResult` instead of a source string. This object contains source, a source hash, and an optional transform.

Use a source hash when the plugin already reads or hashes a file. Klenod uses the hash to detect unchanged modules.

Klenod does not call transform hooks when `LoadResult` contains a transform. Use this option only when the result is complete.

Add a source map when a transform generates Ruby from another language. Runtime errors can then refer to the original file and line.

Store only collection data in transform metadata. Runtime bundles must not contain objects that require build plugins or heavy build dependencies.

## Errors

Return `nil` from `resolve` and `load` when the plugin does not handle the request. Return `super` from other unhandled hooks.

Raise `Klenod::Build::ResolveError` when a plugin cannot resolve an import that it owns. Include the import specifier in the message.

Raise `Klenod::Build::UnsupportedFileError` when a supported file contains unsupported input. Include the module ID in the message.

## Test a Plugin

Create a temporary source directory and use a small plugin list. This method keeps plugin tests independent from application code.

```ruby
require "minitest/autorun"
require "tmpdir"
require "klenod/build"

class MessagePluginTest < Minitest::Test
  def test_transforms_message_files
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "welcome.message"), "Hello\n")

      context = Klenod::Build::Context.new(
        source_dir: dir,
        plugins: [MessagePlugin.new]
      )

      message = context.entry("welcome.message")

      assert_equal "Hello", message.exports::TEXT
    end
  end
end
```

Add only the plugins that the test needs. Add `RubyPlugin::Plugin` when the test imports dependencies from generated or application Ruby code.

Test development evaluation and production bundles when the plugin defines import-value hooks. Test file additions and removals when the plugin defines invalidation behavior.
