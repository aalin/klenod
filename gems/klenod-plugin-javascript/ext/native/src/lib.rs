use magnus::{function, prelude::*, Error, RArray, Ruby};
use swc_core::{
    common::{sync::Lrc, FileName, SourceMap, Span},
    ecma::{
        ast::{
            Callee, ExportAll, ExportNamedSpecifier, ExportSpecifier, Expr, Lit, ModuleDecl,
            ModuleItem,
        },
        parser::{lexer::Lexer, EsSyntax, Parser, StringInput, Syntax},
        visit::{Visit, VisitWith},
    },
};

#[derive(Clone)]
struct ImportRecord {
    specifier: String,
    kind: &'static str,
    start_offset: usize,
    end_offset: usize,
    loc: String,
}

struct ImportVisitor<'a> {
    source_map: Lrc<SourceMap>,
    source_start: u32,
    filename: &'a str,
    records: Vec<ImportRecord>,
}

impl<'a> ImportVisitor<'a> {
    fn push(&mut self, specifier: &str, kind: &'static str, span: Span) {
        let lo = span.lo.0.saturating_sub(self.source_start) as usize;
        let hi = span.hi.0.saturating_sub(self.source_start) as usize;

        self.records.push(ImportRecord {
            specifier: specifier.to_string(),
            kind,
            start_offset: lo + 1,
            end_offset: hi.saturating_sub(1),
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
                );
            }
            ModuleItem::ModuleDecl(ModuleDecl::ExportNamed(export)) => {
                if let Some(src) = &export.src {
                    self.push(
                        src.value.to_string_lossy().as_ref(),
                        "javascript_export",
                        src.span,
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
                    );
                    return;
                }
            }
        }

        call.visit_children_with(self);
    }
}

fn parse_native(ruby: &Ruby, source: String, filename: String) -> Result<RArray, Error> {
    let source_map: Lrc<SourceMap> = Default::default();
    let source_file = source_map.new_source_file(FileName::Custom(filename.clone()).into(), source);
    let lexer = Lexer::new(
        Syntax::Es(EsSyntax {
            import_attributes: true,
            ..Default::default()
        }),
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
    let mut visitor = ImportVisitor {
        source_map,
        source_start: source_file.start_pos.0,
        filename: &filename,
        records: Vec::new(),
    };
    module.visit_with(&mut visitor);

    let records = ruby.ary_new();
    for record in visitor.records {
        let hash = ruby.hash_new();
        hash.aset("specifier", record.specifier)?;
        hash.aset("kind", record.kind)?;
        hash.aset("start_offset", record.start_offset)?;
        hash.aset("end_offset", record.end_offset)?;
        hash.aset("loc", record.loc)?;
        records.push(hash)?;
    }
    Ok(records)
}

#[magnus::init]
fn init(ruby: &Ruby) -> Result<(), Error> {
    let klenod = ruby.define_module("Klenod")?;
    let plugin = klenod.define_module("Plugin")?;
    let javascript = plugin.define_module("JavaScript")?;
    let native = javascript.define_module("Native")?;
    native.define_singleton_method("parse_native", function!(parse_native, 2))?;
    Ok(())
}
