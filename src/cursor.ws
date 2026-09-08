// One statement, and the answer it produces.
//
// A result is not one message. It is `RowsBegin`, then a `RowBatch` for as
// many batches as it takes, then `RowsEnd` -- and the sequence is unbounded,
// because what the frame cap bounds is a single batch and not a result. So a
// cursor is the honest shape for it: rows arrive a batch at a time, are handed
// out one at a time, and the batch before last can be collected while the
// server is still sending. Nothing here ever holds a whole result unless the
// caller asked for one, which `query` below is.
//
// Everything else a statement can produce -- `Ok`, `Count`, `Lines`, `Error` --
// arrives as a single terminal message, and those need no streaming at all.
// The cursor recognises which of the two shapes it has from the first frame
// back and takes the corresponding path.
//
// The loop is `advance` then `row` rather than one call answering `?Row`,
// which would have read better. `!?Row` is the type that shape needs, and W#
// 0.1.1 parses it but cannot compile it: an error union wrapping an optional
// wrapping a value is three machine words of return, and Cranelift is asked
// for more return registers than it has. `!bool` and a separate accessor is
// the same state machine with a return type that fits.
const array = @import("std/array");
const list = @import("std/list");
const conn = @import("./conn.ws");
const message = @import("./message.ws");
const wire = @import("./wire.ws");

/// A statement in progress.
pub const Cursor = struct {
    c: conn.Conn,
    columns: []str,
    /// The batch being handed out, and how far into it `advance` has gone.
    /// `at` counts rows already produced, so the current one is `at - 1`.
    batch: []message.Row,
    at: i64,
    /// Whether rows are still arriving.
    streaming: bool,
    /// The terminal message, once one has been seen.
    answer: message.Answer,
    settled: bool,
};

// ---------------------------------------------------------------------------
// Starting one
// ---------------------------------------------------------------------------

/// Run one QQL statement, streaming whatever it produces.
pub fn cursor(c: conn.Conn, statement: str) !Cursor {
    return try start(c, statement, false);
}

/// The same, through the SQL front end.
pub fn cursor_sql(c: conn.Conn, statement: str) !Cursor {
    return try start(c, statement, true);
}

fn start(c: conn.Conn, statement: str, sql: bool) !Cursor {
    // Claimed before the statement goes out and released by `settle`, so a
    // second statement sent before this one is drained is refused rather than
    // getting somebody else's answers.
    try conn.begin(c);
    try conn.send(c, message.query_frame(statement, sql));

    const cur = Cursor{
        .c = c,
        .columns = no_columns(),
        .batch = no_rows(),
        .at = 0,
        .streaming = false,
        .answer = message.ok_answer(),
        .settled = false,
    };

    // The first frame says which shape the answer has.
    const f = try conn.read_frame(c);

    if (f.kind == wire.T_ROWS_BEGIN) {
        cur.columns = try message.read_columns(f.body);
        cur.streaming = true;
        return cur;
    }
    if (f.kind == wire.T_OK) {
        try message.read_empty(f.body);
        settle(cur, message.ok_answer());
        return cur;
    }
    if (f.kind == wire.T_COUNT) {
        settle(cur, try message.read_count(f.body));
        return cur;
    }
    if (f.kind == wire.T_LINES) {
        settle(cur, message.lines_answer(try message.read_lines(f.body)));
        return cur;
    }
    if (f.kind == wire.T_ERROR) {
        settle(cur, try message.read_failed(f.body));
        return cur;
    }

    // `Ready` is the only message left, and it belongs to the handshake.
    // Seeing one here means the conversation has lost its place.
    settle(cur, message.ok_answer());
    return error.BadMessageOrder;
}

// ---------------------------------------------------------------------------
// Walking it
// ---------------------------------------------------------------------------

/// Load the next row. False when there are no more.
///
/// The batch boundary is invisible from here: running out of rows in hand is
/// what makes the next frame get read, so a caller sees one flat sequence.
pub fn advance(cur: Cursor) !bool {
    var going = true;
    while (going) {
        if (cur.at < array.len(cur.batch)) {
            cur.at += 1;
            return true;
        }
        if (!cur.streaming) { return false; }

        const f = try conn.read_frame(cur.c);

        if (f.kind == wire.T_ROW_BATCH) {
            cur.batch = try message.read_batch(f.body);
            cur.at = 0;
        } else if (f.kind == wire.T_ROWS_END) {
            try message.read_empty(f.body);
            settle(cur, message.rows_answer(cur.columns, no_rows()));
            return false;
        } else if (f.kind == wire.T_ERROR) {
            // "An `Error` may replace any `RowBatch`, which is how a failure
            // partway through a large result is reported; the client must
            // treat rows already received as belonging to a statement that did
            // not finish." Which is why this settles rather than raising: the
            // caller gets the rows it was handed *and* the reason there are no
            // more.
            settle(cur, try message.read_failed(f.body));
            return false;
        } else {
            return error.BadMessageOrder;
        }
    }
    return false;
}

/// The row `advance` last loaded.
pub fn row(cur: Cursor) message.Row {
    if (cur.at < 1 or cur.at > array.len(cur.batch)) {
        panic_index(cur.at - 1, array.len(cur.batch));
    }
    return cur.batch[cur.at - 1];
}

/// The column names, which are known as soon as the cursor exists.
///
/// Bare for a statement reading one table and `table.column` for one reading
/// several. Empty for a statement that produces no rows at all.
pub fn columns(cur: Cursor) []str { return cur.columns; }

/// Whether this statement produces rows.
pub fn has_rows(cur: Cursor) bool { return cur.streaming or array.len(cur.columns) > 0; }

/// Read whatever is left and answer with the terminal message.
///
/// Draining matters even when the rows are not wanted: the connection carries
/// one request at a time, so the next statement cannot go until this one has
/// been read to its end.
///
/// For a result that streamed, the `Rows` this answers with holds the column
/// names and no rows -- they were handed out already. `query` is the call that
/// keeps them.
pub fn finish(cur: Cursor) !message.Answer {
    while (try advance(cur)) { }
    return cur.answer;
}

// ---------------------------------------------------------------------------
// The whole answer at once
// ---------------------------------------------------------------------------

/// Run one QQL statement and collect everything it produces.
///
/// The simple call, and the right one whenever the result is known to be
/// small. It is `cursor` with a loop around it and holds no state the cursor
/// does not.
pub fn query(c: conn.Conn, statement: str) !message.Answer {
    return try collect(try cursor(c, statement));
}

/// The same, through the SQL front end.
pub fn query_sql(c: conn.Conn, statement: str) !message.Answer {
    return try collect(try cursor_sql(c, statement));
}

fn collect(cur: Cursor) !message.Answer {
    if (!cur.streaming) { return try finish(cur); }

    var rows: list.List[message.Row] = list.new();
    while (try advance(cur)) { list.push(rows, row(cur)); }

    // A result the server abandoned partway through is that failure, not a
    // short result: handing back the rows as though they were the whole answer
    // is exactly the mistake the protocol warns about.
    if (message.failed(cur.answer)) { return cur.answer; }
    return message.rows_answer(cur.columns, list.to_array(rows));
}

// ---------------------------------------------------------------------------

fn settle(cur: Cursor, a: message.Answer) void {
    cur.answer = a;
    cur.streaming = false;
    cur.settled = true;
    cur.batch = no_rows();
    cur.at = 0;
    conn.finished(cur.c);
    return;
}

fn no_rows() []message.Row {
    const out: []message.Row = array.new(0);
    return out;
}

fn no_columns() []str {
    const out: []str = array.new(0);
    return out;
}
