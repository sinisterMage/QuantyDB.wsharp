// Talking to a QuantyDB server.
//
//     quantydb serve shop.qdb --listen 127.0.0.1:7878
//     wsharp run examples/hello.ws
//
// Add `--tokens shop.tokens` to the server and set `cfg.token` below to what
// `quantydb token <label>` printed. The token goes on the wire as those
// characters; do not decode the hex first.
const os = @import("std/os");
const text = @import("std/str");
const db = @import("../src/quantydb.ws");

fn main() i64 {
    var cfg = db.config();
    cfg.token = "";

    const c = db.connect_with("127.0.0.1", 7878, cfg) catch {
        print_err("could not reach the server on 127.0.0.1:7878");
        return 1;
    };

    // A statement with nothing to return answers `Ok`; one that changes rows
    // answers `Count`. Either way a refusal comes back as an answer rather
    // than as an error, so `render` has something to say about all of them.
    run(c, "table greetings { id: int @key  who: text  n: int = 0 }");
    run(c, "put greetings { id: 1, who: \"world\", n: 1 }, { id: 2, who: \"elchi\", n: 2 }");
    run(c, "set greetings where id = 1 { n += 40 }");

    // A result set, streamed. The batch boundaries are invisible from here.
    const cur = db.cursor(c, "get greetings { who, n } order by n desc") catch {
        print_err("the query did not go");
        return 2;
    };
    print(text.join(db.columns(cur), " | "));
    while (db.advance(cur) catch return 3) {
        const r = db.row(cur);
        print(text.concat(db.render(r.values[0]), text.concat(" | ", db.render(r.values[1]))));
    }

    // Draining matters even when the rows are not wanted: one request is in
    // flight at a time, so the next statement cannot go until this one ends.
    const done = db.finish(cur) catch return 4;
    if (db.failed(done)) { print_err(db.render(done)); }

    run(c, "del greetings where n > 0");
    run(c, "drop table greetings");

    db.close(c);
    return 0;
}

/// Run one statement and print whatever it produced.
fn run(c: db.Conn, statement: str) void {
    const a = db.query(c, statement) catch {
        print_err(text.concat("could not run: ", statement));
        return;
    };
    print(db.render(a));
    return;
}
