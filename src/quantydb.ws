// QuantyDB, over the wire.
//
// A client for the protocol in QuantyDB's `docs/PROTOCOL.md`, version 1,
// written in W# and depending on nothing but `std`. This file is the whole
// surface: a package presents one module, and everything below is re-exported
// from the file that implements it.
//
//     const db = @import("quantydb/client");
//
//     fn main() i64 {
//         const c = db.connect("127.0.0.1", 7878) catch return 1;
//         const cur = db.cursor(c, "get users { name, score }") catch return 2;
//         while (db.advance(cur) catch return 3) {
//             const r = db.row(cur);
//             print(db.render(r.values[0]));
//         }
//         db.close(c);
//         return 0;
//     }
//
// The connection carries one statement at a time -- the protocol has no
// request ids and cannot interleave answers -- so a cursor must be read to its
// end before the next statement goes. `query` does that for you and hands back
// the whole result; `cursor` lets a large one stream. Concurrency is a second
// connection.
const connection = @import("./conn.ws");
const statement = @import("./cursor.ws");
const answer = @import("./message.ws");
const values = @import("./value.ws");
const format = @import("./wire.ws");

// ---------------------------------------------------------------------------
// Connecting
// ---------------------------------------------------------------------------

pub const Conn = connection.Conn;
pub const Config = connection.Config;

/// The default configuration: no token, sixty seconds of silence allowed.
pub const config = connection.config;

pub const connect = connection.connect;
pub const connect_with = connection.connect_with;

/// Shake hands over a socket you already have.
pub const attach = connection.attach;

pub const close = connection.close;

// ---------------------------------------------------------------------------
// Statements
// ---------------------------------------------------------------------------

pub const Cursor = statement.Cursor;

/// Run one statement and collect everything it produces.
pub const query = statement.query;
pub const query_sql = statement.query_sql;

/// Run one statement and stream its rows.
pub const cursor = statement.cursor;
pub const cursor_sql = statement.cursor_sql;

pub const advance = statement.advance;
pub const row = statement.row;
pub const columns = statement.columns;
pub const has_rows = statement.has_rows;
pub const finish = statement.finish;

// ---------------------------------------------------------------------------
// Answers
// ---------------------------------------------------------------------------

pub const Answer = answer.Answer;
pub const Ok = answer.Ok;
pub const Count = answer.Count;
pub const Rows = answer.Rows;
pub const Lines = answer.Lines;
pub const Failed = answer.Failed;
pub const Row = answer.Row;

pub const KIND_UNKNOWN = answer.KIND_UNKNOWN;
pub const KIND_OK = answer.KIND_OK;
pub const KIND_COUNT = answer.KIND_COUNT;
pub const KIND_ROWS = answer.KIND_ROWS;
pub const KIND_LINES = answer.KIND_LINES;
pub const KIND_FAILED = answer.KIND_FAILED;

pub const kind = answer.kind;

/// Whether the server refused the statement. A refusal is an answer and not a
/// W# error: the connection is still good and the next statement can go.
pub const failed = answer.failed;

// A field cannot be read through a supertype in W#, so these are how an
// `Answer` gives up what it holds. Each answers `error.BadKind` when asked for
// something the answer is not.
pub const verb_of = answer.verb_of;
pub const total_of = answer.total_of;
pub const columns_of = answer.columns_of;
pub const rows_of = answer.rows_of;
pub const lines_of = answer.lines_of;
pub const code_of = answer.code_of;
pub const message_of = answer.message_of;

// ---------------------------------------------------------------------------
// Values
// ---------------------------------------------------------------------------

pub const Value = values.Value;
pub const Null = values.Null;
pub const Bool = values.Bool;
pub const Int = values.Int;
pub const Float = values.Float;
pub const Text = values.Text;
pub const Blob = values.Blob;

pub const tag = values.tag;
pub const is_null = values.is_null;

pub const as_bool = values.as_bool;
pub const as_int = values.as_int;
pub const as_float = values.as_float;
pub const as_text = values.as_text;
pub const as_blob = values.as_blob;

pub const null_value = values.null_value;
pub const bool_value = values.bool_value;
pub const int_value = values.int_value;
pub const float_value = values.float_value;
pub const text_value = values.text_value;
pub const blob_value = values.blob_value;

/// One rendering for both, because a caller printing an answer and a caller
/// printing a cell want the same function name.
///
/// Written out rather than re-exported: `render` is an overload set in each of
/// two modules, and a facade binds one name to one thing. Forwarding is what
/// merges them, and dispatch still reaches every member of both.
pub fn render(v: values.Value) str { return values.render(v); }
pub fn render(a: answer.Answer) str { return answer.render(a); }

// ---------------------------------------------------------------------------
// The protocol's own numbers
// ---------------------------------------------------------------------------
//
// The error codes are the contract -- the messages beside them are for people
// and are free to change -- so a program deciding what to do about a failure
// decides on these.

pub const VERSION = format.VERSION;
pub const MAX_BODY = format.MAX_BODY;

/// Malformed frame or encoding.
pub const E_PROTOCOL = format.E_PROTOCOL;
pub const E_VERSION = format.E_VERSION;
pub const E_UNAUTHENTICATED = format.E_UNAUTHENTICATED;
pub const E_AUTH_FAILED = format.E_AUTH_FAILED;
pub const E_PARSE = format.E_PARSE;
pub const E_EXECUTION = format.E_EXECUTION;

/// The statement waited for the writer past the server's deadline and did not
/// run. **Retrying is correct, and is what this code is for.**
pub const E_WRITE_QUEUE = format.E_WRITE_QUEUE;
pub const E_SHUTTING_DOWN = format.E_SHUTTING_DOWN;

pub const V_NULL = format.V_NULL;
pub const V_BOOL = format.V_BOOL;
pub const V_INT = format.V_INT;
pub const V_FLOAT = format.V_FLOAT;
pub const V_TEXT = format.V_TEXT;
pub const V_BYTES = format.V_BYTES;
