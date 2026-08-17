use magnus::{function, prelude::*, Error, RArray, RHash, Ruby, TryConvert};
use swc_core::{
    common::{
        comments::NoopComments, sync::Lrc, FileName, Globals, Mark, SourceMap, Span, GLOBALS,
    },
    ecma::{
        ast::{
            Callee, ExportAll, ExportNamedSpecifier, ExportSpecifier, Expr, ImportDecl, Lit,
            ModuleDecl, ModuleItem, Pass, Program,
        },
        codegen::{text_writer::JsWriter, Emitter},
        parser::{lexer::Lexer, EsSyntax, Parser, StringInput, Syntax, TsSyntax},
        transforms::{react, typescript::strip},
        visit::{Visit, VisitWith},
    },
};

#[derive(Clone)]
struct ImportRecord {
    specifier: String,
    kind: &'static str,
    start_offset: usize,
    end_offset: usize,
    attributes: Vec<(String, String)>,
    loc: String,
}

struct ImportVisitor<'a> {
    source_map: Lrc<SourceMap>,
    source_start: u32,
    filename: &'a str,
    records: Vec<ImportRecord>,
}

impl<'a> ImportVisitor<'a> {
    fn push(
        &mut self,
        specifier: &str,
        kind: &'static str,
        span: Span,
        attributes: Vec<(String, String)>,
    ) {
        let lo = span.lo.0.saturating_sub(self.source_start) as usize;
        let hi = span.hi.0.saturating_sub(self.source_start) as usize;

        self.records.push(ImportRecord {
            specifier: specifier.to_string(),
            kind,
            start_offset: lo + 1,
            end_offset: hi.saturating_sub(1),
            attributes,
            loc: self.loc(span),
        });
    }

    fn loc(&self, span: Span) -> String {
        let loc = self.source_map.lookup_char_pos(span.lo);
        format!("{}:{}:{}", self.filename, loc.line, loc.col_display + 1)
    }
}

impl Visit for ImportVisitor<'_> {
    fn visit_module_item(&mut self, item: &ModuleItem) {
        match item {
            ModuleItem::ModuleDecl(ModuleDecl::Import(import)) => {
                self.push(
                    import.src.value.to_string_lossy().as_ref(),
                    "javascript_import",
                    import.src.span,
                    import_attributes(import),
                );
            }
            ModuleItem::ModuleDecl(ModuleDecl::ExportNamed(export)) => {
                if let Some(src) = &export.src {
                    self.push(
                        src.value.to_string_lossy().as_ref(),
                        "javascript_export",
                        src.span,
                        Vec::new(),
                    );
                }

                for specifier in &export.specifiers {
                    if let ExportSpecifier::Named(ExportNamedSpecifier {
                        is_type_only: true, ..
                    }) = specifier
                    {
                        continue;
                    }
                }
            }
            ModuleItem::ModuleDecl(ModuleDecl::ExportAll(ExportAll { src, .. })) => {
                self.push(
                    src.value.to_string_lossy().as_ref(),
                    "javascript_export",
                    src.span,
                    Vec::new(),
                );
            }
            _ => {
                item.visit_children_with(self);
            }
        }
    }

    fn visit_call_expr(&mut self, call: &swc_core::ecma::ast::CallExpr) {
        if matches!(call.callee, Callee::Import(_)) {
            if let Some(first_arg) = call.args.first() {
                if let Expr::Lit(Lit::Str(string)) = &*first_arg.expr {
                    self.push(
                        string.value.to_string_lossy().as_ref(),
                        "javascript_dynamic_import",
                        string.span,
                        Vec::new(),
                    );
                    return;
                }
            }
        }

        call.visit_children_with(self);
    }
}

fn parse_native(ruby: &Ruby, source: String, filename: String) -> Result<RArray, Error> {
    let parsed = parse_module(ruby, source, filename.clone(), SourceKind::JavaScript)?;
    records_to_array(
        ruby,
        import_records(
            parsed.source_map,
            parsed.source_start,
            &filename,
            &parsed.program,
        ),
    )
}

fn transform_native(
    ruby: &Ruby,
    source: String,
    filename: String,
    source_kind: String,
    options: RHash,
) -> Result<RHash, Error> {
    let source_kind = SourceKind::from_string(ruby, &source_kind)?;
    let minify = hash_fetch_bool(options, "minify", false)?;
    let transformed_source = transform_source(ruby, source, filename.clone(), source_kind, minify)?;
    let parsed = parse_module(
        ruby,
        transformed_source.clone(),
        filename.clone(),
        SourceKind::JavaScript,
    )?;
    let hash = ruby.hash_new();
    hash.aset("code", transformed_source)?;
    hash.aset(
        "imports",
        records_to_array(
            ruby,
            import_records(
                parsed.source_map,
                parsed.source_start,
                &filename,
                &parsed.program,
            ),
        )?,
    )?;
    Ok(hash)
}

#[derive(Clone, Copy)]
enum SourceKind {
    JavaScript,
    TypeScript,
    JavaScriptJsx,
    TypeScriptJsx,
}

impl SourceKind {
    fn from_string(ruby: &Ruby, source_kind: &str) -> Result<Self, Error> {
        match source_kind {
            "javascript" => Ok(Self::JavaScript),
            "typescript" => Ok(Self::TypeScript),
            "javascript_jsx" => Ok(Self::JavaScriptJsx),
            "typescript_jsx" => Ok(Self::TypeScriptJsx),
            _ => Err(Error::new(
                ruby.exception_arg_error(),
                format!("unknown JavaScript source kind: {}", source_kind),
            )),
        }
    }
}

struct ParsedProgram {
    source_map: Lrc<SourceMap>,
    source_start: u32,
    program: Program,
}

fn parse_module(
    ruby: &Ruby,
    source: String,
    filename: String,
    source_kind: SourceKind,
) -> Result<ParsedProgram, Error> {
    let source_map: Lrc<SourceMap> = Default::default();
    let source_file = source_map.new_source_file(FileName::Custom(filename.clone()).into(), source);
    let lexer = Lexer::new(
        syntax_for(source_kind),
        Default::default(),
        StringInput::from(&*source_file),
        None,
    );
    let mut parser = Parser::new_from(lexer);
    let module = parser.parse_module().map_err(|error| {
        Error::new(
            ruby.exception_syntax_error(),
            format!("{}: {}", filename, error.kind().msg()),
        )
    })?;
    Ok(ParsedProgram {
        source_map,
        source_start: source_file.start_pos.0,
        program: Program::Module(module),
    })
}

fn syntax_for(source_kind: SourceKind) -> Syntax {
    match source_kind {
        SourceKind::JavaScript => Syntax::Es(EsSyntax {
            import_attributes: true,
            ..Default::default()
        }),
        SourceKind::JavaScriptJsx => Syntax::Es(EsSyntax {
            import_attributes: true,
            jsx: true,
            ..Default::default()
        }),
        SourceKind::TypeScript => Syntax::Typescript(TsSyntax {
            tsx: false,
            decorators: true,
            ..Default::default()
        }),
        SourceKind::TypeScriptJsx => Syntax::Typescript(TsSyntax {
            tsx: true,
            decorators: true,
            ..Default::default()
        }),
    }
}

fn import_records(
    source_map: Lrc<SourceMap>,
    source_start: u32,
    filename: &str,
    program: &Program,
) -> Vec<ImportRecord> {
    let mut visitor = ImportVisitor {
        source_map,
        source_start,
        filename,
        records: Vec::new(),
    };
    program.visit_with(&mut visitor);

    visitor.records
}

fn import_attributes(import: &ImportDecl) -> Vec<(String, String)> {
    import
        .with
        .as_ref()
        .and_then(|with| with.as_import_with())
        .map(|with| {
            with.values
                .iter()
                .map(|item| {
                    (
                        item.key.sym.to_string(),
                        item.value.value.to_string_lossy().to_string(),
                    )
                })
                .collect()
        })
        .unwrap_or_default()
}

fn records_to_array(ruby: &Ruby, records: Vec<ImportRecord>) -> Result<RArray, Error> {
    let array = ruby.ary_new();
    for record in records {
        let hash = ruby.hash_new();
        hash.aset("specifier", record.specifier)?;
        hash.aset("kind", record.kind)?;
        hash.aset("start_offset", record.start_offset)?;
        hash.aset("end_offset", record.end_offset)?;
        let attributes = ruby.hash_new();
        for (key, value) in record.attributes {
            attributes.aset(key, value)?;
        }
        hash.aset("attributes", attributes)?;
        hash.aset("loc", record.loc)?;
        array.push(hash)?;
    }
    Ok(array)
}

fn transform_source(
    ruby: &Ruby,
    source: String,
    filename: String,
    source_kind: SourceKind,
    minify: bool,
) -> Result<String, Error> {
    if !source_kind.needs_transform() && !minify {
        return Ok(source);
    }

    let parsed = parse_module(ruby, source, filename, source_kind)?;
    let source_map = parsed.source_map;
    let mut program = parsed.program;

    GLOBALS.set(&Globals::default(), || {
        let unresolved_mark = Mark::new();
        let top_level_mark = Mark::new();
        if source_kind.is_typescript() {
            strip(unresolved_mark, top_level_mark).process(&mut program);
        }
        if source_kind.is_jsx() {
            react::jsx(
                source_map.clone(),
                None::<NoopComments>,
                react::Options {
                    pragma: Some("h".into()),
                    pragma_frag: Some("Fragment".into()),
                    ..Default::default()
                },
                top_level_mark,
                unresolved_mark,
            )
            .process(&mut program);
        }
    });

    let mut bytes = Vec::new();
    {
        let writer = JsWriter::new(source_map.clone(), "\n", &mut bytes, None);
        let mut emitter = Emitter {
            cfg: swc_core::ecma::codegen::Config::default().with_minify(minify),
            cm: source_map,
            comments: None,
            wr: writer,
        };
        emitter.emit_program(&program).map_err(|error| {
            Error::new(
                ruby.exception_runtime_error(),
                format!("failed to emit JavaScript from TypeScript: {}", error),
            )
        })?;
    }

    String::from_utf8(bytes).map_err(|error| {
        Error::new(
            ruby.exception_runtime_error(),
            format!("SWC generated invalid UTF-8: {}", error),
        )
    })
}

fn hash_fetch_bool(hash: RHash, key: &str, default: bool) -> Result<bool, Error> {
    match hash.get(key) {
        Some(value) => bool::try_convert(value),
        None => Ok(default),
    }
}

impl SourceKind {
    fn needs_transform(self) -> bool {
        self.is_typescript() || self.is_jsx()
    }

    fn is_typescript(self) -> bool {
        matches!(self, SourceKind::TypeScript | SourceKind::TypeScriptJsx)
    }

    fn is_jsx(self) -> bool {
        matches!(self, SourceKind::JavaScriptJsx | SourceKind::TypeScriptJsx)
    }
}

#[magnus::init]
fn init(ruby: &Ruby) -> Result<(), Error> {
    let klenod = ruby.define_module("Klenod")?;
    let plugin = klenod.define_module("Plugin")?;
    let javascript = plugin.define_module("JavaScript")?;
    let native = javascript.define_module("Native")?;
    native.define_singleton_method("parse_native", function!(parse_native, 2))?;
    native.define_singleton_method("transform_native", function!(transform_native, 4))?;
    Ok(())
}
