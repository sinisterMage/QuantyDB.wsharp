// Messages: the four a client sends, and what the eight it receives mean.
//
// An answer is the same shape as a value -- an empty base struct and one
// subtype per case -- for the same reason, and with the same consequence:
// **W# resolves a field by the object's declared type**, so a caller holding an
// `Answer` cannot write `a.rows` even when it is a `Rows`. The accessors below
// are how it gets there, and they are why the base overload of each answers
// `error.BadKind` rather than a default. `std/toml` reaches its `Value` the
// same way.
//
// Assembling a result is not here. `RowsBegin`, `RowBatch` and `RowsEnd` are
// three messages describing one answer that arrives over an unbounded number
// of frames, so joining them up belongs to the thing that owns the socket --
// `cursor.ws`. What is here is one message body at a time, decoded and
// bounds-checked, with no memory of the last one.
const array = @import("std/array");
const bytes = @import("std/bytes");
const text = @import("std/str");
const value = @import("./value.ws");
const wire = @import("./wire.ws");

/// One row of a result.
///
/// An array rather than a `list.List`: see the note on `value.decode_row`.
pub const Row = struct { values: []value.Value };

pub const Answer = struct { };
pub const Ok = struct : Answer { };
pub const Count = struct : Answer { verb: str, n: u64 };
pub const Rows = struct : Answer { columns: []str, rows: []Row };
pub const Lines = struct : Answer { lines: []str };

/// The protocol's `Error`, with the code that is the contract and the message
/// that is for people.
///
/// Named `Failed` rather than `Error` only to keep it clear of `error.X`, which
/// is a different thing entirely: a statement the server refuses is an ordinary
/// answer and leaves the connection good for the next one, where a W# error out
/// of this driver means the conversation itself has broken.
pub const Failed = struct : Answer { code: i64, message: str };

pub const KIND_UNKNOWN = 0;
pub const KIND_OK = 1;
pub const KIND_COUNT = 2;
pub const KIND_ROWS = 3;
pub const KIND_LINES = 4;
pub const KIND_FAILED = 5;

pub fn kind(a: Answer) i64 { return KIND_UNKNOWN; }
pub fn kind(a: Ok) i64 { return KIND_OK; }
pub fn kind(a: Count) i64 { return KIND_COUNT; }
pub fn kind(a: Rows) i64 { return KIND_ROWS; }
pub fn kind(a: Lines) i64 { return KIND_LINES; }
pub fn kind(a: Failed) i64 { return KIND_FAILED; }

/// Whether the server refused the statement.
pub fn failed(a: Answer) bool { return false; }
pub fn failed(a: Failed) bool { return true; }

// ---------------------------------------------------------------------------
// Constructors
// ---------------------------------------------------------------------------
//
// Answering `Answer` rather than the subtype, for `value.ws`'s reason: W# will
// coerce a subtype to its supertype, and a value into an `!T`, but not both in
// one step.

pub fn ok_answer() Answer { return Ok{ }; }
pub fn count_answer(verb: str, n: u64) Answer { return Count{ .verb = verb, .n = n }; }
pub fn lines_answer(lines: []str) Answer { return Lines{ .lines = lines }; }
pub fn failed_answer(code: i64, message: str) Answer {
    return Failed{ .code = code, .message = message };
}
pub fn rows_answer(columns: []str, rows: []Row) Answer {
    return Rows{ .columns = columns, .rows = rows };
}

// ---------------------------------------------------------------------------
// Reading one out
// ---------------------------------------------------------------------------

pub fn verb_of(a: Answer) !{BadKind}str { return error.BadKind; }
pub fn verb_of(a: Count) !{BadKind}str { return a.verb; }

pub fn total_of(a: Answer) !{BadKind}u64 { return error.BadKind; }
pub fn total_of(a: Count) !{BadKind}u64 { return a.n; }

pub fn columns_of(a: Answer) !{BadKind}[]str { return error.BadKind; }
pub fn columns_of(a: Rows) !{BadKind}[]str { return a.columns; }

pub fn rows_of(a: Answer) !{BadKind}[]Row { return error.BadKind; }
pub fn rows_of(a: Rows) !{BadKind}[]Row { return a.rows; }

pub fn lines_of(a: Answer) !{BadKind}[]str { return error.BadKind; }
pub fn lines_of(a: Lines) !{BadKind}[]str { return a.lines; }

pub fn code_of(a: Answer) !{BadKind}i64 { return error.BadKind; }
pub fn code_of(a: Failed) !{BadKind}i64 { return a.code; }

pub fn message_of(a: Answer) !{BadKind}str { return error.BadKind; }
pub fn message_of(a: Failed) !{BadKind}str { return a.message; }

// ---------------------------------------------------------------------------
// Rendering
// ---------------------------------------------------------------------------
//
// What `quantydb connect` prints for the same answer, so that the two can be
// held against each other: `ok` for an answer with nothing in it, the verb and
// the number for a count, one line per line, and one line per row with the
// values separated by a bar. Column names are not printed, because the local
// path has none to print.

pub fn render(a: Answer) str { return ""; }
pub fn render(a: Ok) str { return "ok"; }
pub fn render(a: Lines) str { return text.join(a.lines, "\n"); }

pub fn render(a: Count) str {
    return text.concat(text.concat(a.verb, " "), text.from_uint(a.n));
}

pub fn render(a: Failed) str { return a.message; }

pub fn render(a: Rows) str {
    var out: []str = array.new(array.len(a.rows));
    var i = 0;
    while (i < array.len(a.rows)) : (i += 1) {
        const row = a.rows[i];
        var cells: []str = array.new(array.len(row.values));
        var j = 0;
        while (j < array.len(row.values)) : (j += 1) {
            cells[j] = value.render(row.values[j]);
        }
        out[i] = text.join(cells, "|");
    }
    return text.join(out, "\n");
}

// ---------------------------------------------------------------------------
// Client messages
// ---------------------------------------------------------------------------

/// `Auth`, carrying the token.
///
/// **The token goes on the wire as the characters it is printed as.**
/// `quantydb token` prints sixty-four hexadecimal characters and those sixty-
/// four bytes are what this carries, not the thirty-two they spell. The server
/// hashes what arrives, so decoding the hex first produces a different hash and
/// a refusal that says nothing about why. `str` is arbitrary bytes in W#, so
/// writing the string straight out is both the simplest thing and the right
/// one.
pub fn auth_frame(token: str) []u8 {
    const b = bytes.buf(wire.HEADER_LEN + text.len(token));
    wire.put_text(b, token);
    return wire.frame(wire.T_AUTH, bytes.taken(b));
}

/// `Query` or `QuerySql`, carrying one statement.
///
/// The statement carries its own length inside the body even though the frame
/// header has already given one. That is redundant and deliberate -- every
/// variable length field in this protocol is written the same way -- and it is
/// the single mistake the specification says a client is most likely to make.
pub fn query_frame(statement: str, sql: bool) []u8 {
    const b = bytes.buf(wire.HEADER_LEN + text.len(statement));
    wire.put_text(b, statement);
    if (sql) { return wire.frame(wire.T_QUERY_SQL, bytes.taken(b)); }
    return wire.frame(wire.T_QUERY, bytes.taken(b));
}

/// `Close`: an orderly goodbye, so the server sees an ending rather than a
/// connection that disappeared.
pub fn close_frame() []u8 {
    return wire.frame(wire.T_CLOSE, bytes.new(0));
}

// ---------------------------------------------------------------------------
// Server message bodies
// ---------------------------------------------------------------------------
//
// Each takes the body the frame header measured and reads it to the end. The
// `done` at the end of every one is not ceremony: bytes left over mean the
// sender and this decoder disagree about the format, and the message that
// caused it is the only place that is cheap to find out.

/// A body that must be empty: `Ready`, `Ok` and `RowsEnd`.
pub fn read_empty(body: []u8) !void {
    if (array.len(body) != 0) { return error.Trailing; }
    return;
}

pub fn read_count(body: []u8) !Answer {
    const r = wire.reader(body);
    const verb = try wire.utf8_text(r);
    const n = try wire.u64le(r);
    try wire.done(r);
    return count_answer(verb, n);
}

/// `RowsBegin`: the column names.
///
/// Bare when a statement reads one table and qualified as `table.column` when
/// it reads several, because a join of two tables with a `name` column each
/// would otherwise send the same header twice.
pub fn read_columns(body: []u8) ![]str {
    const r = wire.reader(body);
    const n = try wire.count(r, wire.MAX_VALUES_PER_ROW);
    var out: []str = array.new(n);
    var i = 0;
    while (i < n) : (i += 1) {
        out[i] = try wire.utf8_text(r);
    }
    try wire.done(r);
    return out;
}

/// `RowBatch`: a chunk of rows, sized by the sender to fit in a frame.
pub fn read_batch(body: []u8) ![]Row {
    const r = wire.reader(body);
    const n = try wire.count(r, wire.MAX_ROWS_PER_BATCH);
    var out: []Row = array.new(n);
    var i = 0;
    while (i < n) : (i += 1) {
        out[i] = Row{ .values = try value.decode_row(r) };
    }
    try wire.done(r);
    return out;
}

pub fn read_lines(body: []u8) ![]str {
    const r = wire.reader(body);
    const n = try wire.count(r, wire.MAX_LINES);
    var out: []str = array.new(n);
    var i = 0;
    while (i < n) : (i += 1) {
        out[i] = try wire.utf8_text(r);
    }
    try wire.done(r);
    return out;
}

pub fn read_failed(body: []u8) !Answer {
    const r = wire.reader(body);
    const code = try wire.u16le(r);
    const message = try wire.utf8_text(r);
    try wire.done(r);
    return failed_answer(code, message);
}
