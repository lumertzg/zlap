//! Public API for zlap's table-driven command parser.
//!
//! `Argv` words and environment values are borrowed. Scalar text fields borrow their
//! source. Binding allocates list backing storage with its caller-supplied allocator,
//! and the caller owns that storage. An action event wins over an earlier diagnostic.
//! Otherwise the first diagnostic wins, and a parser syntax error is terminal.

pub const schema = @import("schema.zig");
const bind = @import("bind.zig");
const compile = @import("compile.zig");
const render = @import("render.zig");
const process = @import("process.zig");
const response = @import("response.zig");
const spec_module = @import("spec.zig");
const completion = @import("completion.zig");
pub const testing = @import("testing.zig");

pub const Action = schema.Action;
pub const Argv = schema.Argv;
pub const CmdId = schema.CmdId;
pub const Command = schema.Command;
pub const Diagnostic = schema.Diagnostic;
pub const Env = schema.Env;
pub const ExternalCommand = schema.ExternalCommand;
pub const Error = schema.Error;
pub const Event = schema.Event;
pub const FieldMeta = schema.FieldMeta;
pub const Flag = schema.Flag;
pub const FlagId = schema.FlagId;
pub const Meta = schema.Meta;
pub const Name = schema.Name;
pub const Options = schema.Options;
pub const Parser = schema.Parser;
pub const Scope = schema.Scope;
pub const Table = schema.Table;
pub const Target = schema.Target;
pub const UnknownFlags = schema.UnknownFlags;
pub const ValueKind = schema.ValueKind;
pub const Variant = schema.Variant;
pub const VariantsMeta = schema.VariantsMeta;
pub const Node = compile.Node;
pub const Binding = compile.Binding;

pub const defaults = bind.defaults;
pub const parseFrom = bind.parseFrom;
pub const fill = bind.fill;
pub const updateFrom = bind.updateFrom;
pub const Compiled = compile.Compiled;
pub const Style = render.Style;
pub const writeHelp = render.writeHelp;
pub const writeVersion = render.writeVersion;
pub const renderDiagnostic = render.renderDiagnostic;
pub const parse = process.parse;
pub const ExpandedArgv = response.ExpandedArgv;
pub const ResponseOptions = response.Options;
pub const expandResponseFiles = response.expandResponseFiles;
pub const spec = spec_module.spec;
pub const Shell = completion.Shell;
pub const completionScript = completion.completionScript;
pub const complete = completion.complete;

test {
    _ = schema;
    _ = bind;
    _ = compile;
    _ = render;
    _ = process;
    _ = response;
    _ = spec_module;
    _ = completion;
    _ = testing;
}
