// The driver against a real `quantydb serve`.
//
//     wsharp run tests/live/main.ws -- <host> <port> <token>
//
// Driven by `tests/live.sh`, which builds the server, mints the token and
// diffs this output against what it should be. Kept out of `tests/` proper so
// that `run.sh`'s glob does not pick up a case needing a server.
//
// What the offline suite cannot check is here: that the bytes this driver
// writes are the bytes a real server accepts, and that what it reads back is
// what a real server sends. The fixtures could agree with a misreading of the
// specification; a running server cannot.
const array = @import("std/array");
const os = @import("std/os");
const text = @import("std/str");
const db = @import("../../src/quantydb.ws");

fn shows(label: str, v: str) void { print(text.concat(label, text.concat(": ", v))); return; }

fn check(label: str, v: bool) void {
    if (v) { shows(label, "true"); } else { shows(label, "false"); }
    return;
}

/// Run one statement and print what came back.
fn run(c: db.Conn, label: str, statement: str) void {
    const a = db.query(c, statement) catch {
        shows(label, "<the statement did not go>");
        return;
    };
    shows(label, db.render(a));
    return;
}

/// The same, through the SQL front end -- which is a different message type
/// and nothing else. Sending SQL to `Query` gets it parsed as QQL, and the
/// complaint that follows names QQL's statements rather than saying the front
/// end was wrong.
fn run_sql(c: db.Conn, label: str, statement: str) void {
    const a = db.query_sql(c, statement) catch {
        shows(label, "<the statement did not go>");
        return;
    };
    shows(label, db.render(a));
    return;
}

fn main() i64 {
    const argv = os.args();
    if (array.len(argv) < 3) {
        print_err("usage: main.ws -- <host> <port> <token>");
        return 2;
    }
    const host = argv[0];
    const port = text.parse_int(argv[1]) catch return 2;
    const token = argv[2];

    var cfg = db.config();
    cfg.token = token;
    const c = db.connect_with(host, port, cfg) catch {
        print_err("could not connect");
        return 1;
    };

    // Schema and mutations: `Ok` for a statement with nothing to return, and
    // `Count` with the verb and how many rows it touched.
    run(c, "table", "table things { id: int @key  ratio: float  label: text  raw: bytes  flag: bool  spare: text @null }");
    run(c, "put", "put things { id: 1, ratio: 2.5, label: \"hi\", raw: x\"beef\", flag: true }, { id: 2, ratio: 0.5, label: \"there\", raw: x\"\", flag: false }");
    run(c, "set", "set things where id = 1 { ratio = 3.25 }");

    // Every value type, over the wire and back.
    const cur = db.cursor(c, "get things { id, ratio, label, raw, flag, spare } order by id") catch {
        print_err("the query did not go");
        return 1;
    };
    shows("columns", text.join(db.columns(cur), ","));
    while (db.advance(cur) catch return 1) {
        const r = db.row(cur);
        var cells: []str = array.new(array.len(r.values));
        var i = 0;
        while (i < array.len(r.values)) : (i += 1) { cells[i] = db.render(r.values[i]); }
        shows("row", text.join(cells, "|"));
    }
    const ended = db.finish(cur) catch return 1;
    check("the result ended cleanly", !db.failed(ended));

    // The tags each column actually arrived as, which is what says the value
    // decoder and the server's encoder agree rather than merely round-tripping.
    const typed = db.query(c, "get things { id, ratio, label, raw, flag, spare } where id = 1") catch return 1;
    const rows = db.rows_of(typed) catch return 1;
    check("one row came back", array.len(rows) == 1);
    const v = rows[0].values;
    check("int, float, text, bytes, bool, null",
        db.tag(v[0]) == db.V_INT and db.tag(v[1]) == db.V_FLOAT
        and db.tag(v[2]) == db.V_TEXT and db.tag(v[3]) == db.V_BYTES
        and db.tag(v[4]) == db.V_BOOL and db.tag(v[5]) == db.V_NULL);
    check("and their contents", (db.as_int(v[0]) catch -1) == 1
        and (db.as_float(v[1]) catch 0.0) == 3.25
        and text.eq(db.as_text(v[2]) catch "", "hi")
        and db.as_bool(v[4]) catch false
        and db.is_null(v[5]));

    // `Lines`, which is what `show` and `log` produce.
    const listed = db.query(c, "show tables") catch return 1;
    check("show tables is lines", db.kind(listed) == db.KIND_LINES);
    shows("show tables", db.render(listed));
    check("log is lines", db.kind(db.query(c, "log") catch return 1) == db.KIND_LINES);

    // The SQL front end, over the other message type.
    run_sql(c, "sql", "SELECT label FROM things WHERE id = 2");

    // A statement the server refuses. An answer, not an error: the connection
    // is still good, which the statement after it proves.
    const bad = db.query(c, "get nosuchtable") catch return 1;
    check("a bad statement is a failure answer", db.failed(bad));
    check("with a code, not just a sentence", (db.code_of(bad) catch -1) > 0);
    run(c, "still usable", "show tables");

    // Enough rows to make streaming do some work.
    run(c, "many", "put things { id: 3, ratio: 1.0, label: \"a\", raw: x\"\", flag: true }, { id: 4, ratio: 1.0, label: \"b\", raw: x\"\", flag: true }, { id: 5, ratio: 1.0, label: \"c\", raw: x\"\", flag: true }");
    shows("streamed", text.from_int(counted(c, "get things { id } order by id")));

    run(c, "del", "del things where id > 2");
    run(c, "drop", "drop table things");
    db.close(c);

    // A connection that shows no token, against a server that wants one:
    // everything is answered `0x0003` until an `Auth` has been accepted.
    var anonymous = db.config();
    const nobody = db.connect_with(host, port, anonymous) catch {
        print_err("could not connect anonymously");
        return 1;
    };
    const refused = db.query(nobody, "show tables") catch return 1;
    check("unauthenticated", (db.code_of(refused) catch -1) == db.E_UNAUTHENTICATED);
    db.close(nobody);

    // A token the server does not know. The hex is well-formed and wrong.
    var wrong = db.config();
    wrong.token = "0000000000000000000000000000000000000000000000000000000000000000";
    check("a wrong token is refused", !connects(host, port, wrong));
    return 0;
}

fn counted(c: db.Conn, statement: str) i64 {
    const cur = db.cursor(c, statement) catch return -1;
    var n = 0;
    while (db.advance(cur) catch return -1) { n += 1; }
    const done = db.finish(cur) catch return -1;
    return n;
}

fn connects(host: str, port: i64, cfg: db.Config) bool {
    const c = db.connect_with(host, port, cfg) catch return false;
    db.close(c);
    return true;
}
