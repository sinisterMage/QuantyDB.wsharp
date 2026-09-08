// A whole conversation, against a server made of canned bytes.
//
// Both ends of a loopback pair are held by this one worker. Connecting to your
// own listener completes through the backlog without anybody having accepted
// yet, so `connect` and then `accept` in that order needs no second thread --
// which matters, because W#'s worker calls are synchronous RPC and a fake
// server running inside one would deadlock against the client waiting on it.
//
// So the server's answers are written into the socket first and the driver
// reads them as though they had just arrived. What the driver *sent* is read
// back afterwards and checked byte for byte, which is the half a fixture test
// cannot reach.
// expect: the hello the driver sent: 5155414e5459010000
// expect: ok
// expect: what the driver sent: query "table t { id: int @key }"
// expect: put 2
// expect: what the driver sent: query "put t { id: 1 }, { id: 2 }"
// expect: first line
// expect: second line
// expect: what the driver sent: query "log"
// expect: sql goes to the other front end: true
// expect: what the driver sent: sql "SELECT 1"
// expect: columns: id|name
// expect: 1|a
// expect: 2|bb
// expect: 3|ccc
// expect: rows arrived across two batches: 3
// expect: the terminal answer is the result: 3
// expect: collected at once: 1|a
// expect: a statement the server refused: boom
// expect: refused with the parse error code: true
// expect: a refusal is not a transport failure: true
// expect: the connection still works afterwards: ok
// expect: rows already received, then a failure: 1
// expect: and the failure is what finish reports: gone
// expect: a second statement before the first is drained: false
// expect: a token is sent as its characters: 100700000003000000616263
// expect: a token the server refuses: false
// expect: a handshake the server turns away: false
// expect: silence, until the timeout: false
const array = @import("std/array");
const bytes = @import("std/bytes");
const net = @import("std/net");
const text = @import("std/str");
const db = @import("../src/quantydb.ws");

// The server's side of an accepted handshake: `01`, the version, no reason --
// and then the unprompted `Ready` that every accepted handshake is followed
// by, whether or not a token is wanted.
const ACCEPTED = "010100002000000000";

/// `RowsBegin` naming `id` and `name`.
const ROWS_BEGIN = "231200000002000000020000006964040000006e616d65";
/// Two rows: `1, "a"` and `2, "bb"`.
const BATCH_TWO = "242b00000002000000020000000301000000000000000501000000610200000003020000000000000005020000006262";
/// One row: `3, "ccc"`.
const BATCH_ONE = "241900000001000000020000000303000000000000000503000000636363";
const ROWS_END = "2500000000";

const Pair = struct { client: net.Socket, server: net.Socket };

fn pair() !Pair {
    const l = try net.listen("127.0.0.1", 0, 1);
    const port = try net.local_port(l);
    const c = try net.connect("127.0.0.1", port);
    const s = try net.accept(l);
    net.close_listener(l);
    return Pair{ .client = c, .server = s };
}

/// A pair whose server end has already accepted a handshake.
fn opened() !Pair {
    const p = try pair();
    say(p, ACCEPTED);
    return p;
}

/// Put bytes where the driver will read them.
fn say(p: Pair, h: str) void {
    const b = bytes.from_hex(h) catch return;
    net.write_all_bytes(p.server, b, 0, array.len(b)) catch return;
    return;
}

/// The next `n` bytes the driver sent, as hex.
fn heard(p: Pair, n: i64) str {
    const b = bytes.new(n);
    net.read_exactly_into(p.server, b, 0, n) catch return "<short>";
    return bytes.to_hex(b);
}

/// The next whole frame the driver sent, described.
fn sent(p: Pair) str {
    const head = bytes.new(5);
    net.read_exactly_into(p.server, head, 0, 5) catch return "<short>";
    const kind = i64(head[0]);
    const n = i64(bytes.le32(head, 1));
    const body = bytes.new(n);
    if (n > 0) { net.read_exactly_into(p.server, body, 0, n) catch return "<short>"; }

    if (kind == 0x13) { return "close"; }
    // Every variable length field is a u32 length and then that many bytes, so
    // the statement starts four bytes in.
    const s = bytes.slice_str(body, 4, array.len(body));
    if (kind == 0x10) { return quoted("auth ", s); }
    if (kind == 0x11) { return quoted("query ", s); }
    if (kind == 0x12) { return quoted("sql ", s); }
    return "<unknown>";
}

/// Read the next frame the driver sent and throw it away.
fn skip(p: Pair) void {
    const ignored = sent(p);
    return;
}

fn quoted(prefix: str, s: str) str {
    return text.concat(prefix, text.concat("\"", text.concat(s, "\"")));
}

fn shows(label: str, v: str) void { print(text.concat(label, text.concat(": ", v))); return; }

fn check(label: str, v: bool) void {
    if (v) { shows(label, "true"); } else { shows(label, "false"); }
    return;
}

fn main() i64 {
    const p = opened() catch return 1;
    var cfg = db.config();
    cfg.timeout_ms = 0;
    const c = db.attach(p.client, cfg) catch return 2;
    shows("the hello the driver sent", heard(p, 9));

    // An answer with nothing in it.
    say(p, "2100000000");
    print(db.render(db.query(c, "table t { id: int @key }") catch return 3));
    shows("what the driver sent", sent(p));

    // A count: the verb, and how many rows it touched.
    say(p, "220f000000030000007075740200000000000000");
    print(db.render(db.query(c, "put t { id: 1 }, { id: 2 }") catch return 4));
    shows("what the driver sent", sent(p));

    // Lines, which is what `log` and `show` produce.
    say(p, "2621000000020000000a0000006669727374206c696e650b0000007365636f6e64206c696e65");
    print(db.render(db.query(c, "log") catch return 5));
    shows("what the driver sent", sent(p));

    // The SQL front end is a different message type and nothing else.
    say(p, "2100000000");
    check("sql goes to the other front end",
        db.kind(db.query_sql(c, "SELECT 1") catch return 6) == db.KIND_OK);
    shows("what the driver sent", sent(p));

    // A result that streams: begin, two batches, end. The batch boundary is
    // invisible to the loop, which is the whole point of the cursor.
    say(p, ROWS_BEGIN);
    say(p, BATCH_TWO);
    say(p, BATCH_ONE);
    say(p, ROWS_END);
    const cur = db.cursor(c, "get t { id, name }") catch return 7;
    shows("columns", text.join(db.columns(cur), "|"));
    var seen = 0;
    while (db.advance(cur) catch return 8) {
        const r = db.row(cur);
        print(text.concat(db.render(r.values[0]), text.concat("|", db.render(r.values[1]))));
        seen += 1;
    }
    shows("rows arrived across two batches", text.from_int(seen));
    shows("the terminal answer is the result",
        text.from_int(db.kind(db.finish(cur) catch return 9)));
    skip(p);

    // The same shape, collected in one call.
    say(p, ROWS_BEGIN);
    say(p, BATCH_TWO);
    say(p, ROWS_END);
    const all = db.query(c, "get t { id, name }") catch return 10;
    const rows = db.rows_of(all) catch return 11;
    shows("collected at once",
        text.concat(db.render(rows[0].values[0]), text.concat("|", db.render(rows[0].values[1]))));
    skip(p);

    // A statement the server refuses. Not a transport failure: the connection
    // is still good and the next statement can go, which the line after checks
    // rather than assumes.
    say(p, "270a000000050004000000626f6f6d");
    const refused = db.query(c, "get nosuch") catch return 12;
    shows("a statement the server refused", db.render(refused));
    check("refused with the parse error code", (db.code_of(refused) catch -1) == db.E_PARSE);
    check("a refusal is not a transport failure", db.failed(refused));
    skip(p);
    say(p, "2100000000");
    shows("the connection still works afterwards",
        db.render(db.query(c, "table u { id: int @key }") catch return 13));
    skip(p);

    // "An `Error` may replace any `RowBatch`" -- the rows already handed out
    // belong to a statement that did not finish.
    say(p, ROWS_BEGIN);
    say(p, "2418000000010000000200000003010000000000000005020000006161");
    say(p, "270a000000060004000000676f6e65");
    const partial = db.cursor(c, "get t { id, name }") catch return 14;
    var got = 0;
    while (db.advance(partial) catch return 15) { got += 1; }
    shows("rows already received, then a failure", text.from_int(got));
    shows("and the failure is what finish reports",
        db.message_of(db.finish(partial) catch return 16) catch "?");
    skip(p);

    // One request in flight. A second statement before the first is drained is
    // refused rather than handed somebody else's answers.
    say(p, ROWS_BEGIN);
    const held = db.cursor(c, "get t { id, name }") catch return 17;
    check("a second statement before the first is drained", starts(c, "get t"));

    // A token goes on the wire as the characters it is printed as -- sixty-four
    // hex characters, not the thirty-two bytes they spell. Here, three.
    const q = opened() catch return 18;
    say(q, "2000000000");
    var with_token = db.config();
    with_token.timeout_ms = 0;
    with_token.token = "abc";
    const authed = db.attach(q.client, with_token) catch return 19;
    const opening = heard(q, 9);
    shows("a token is sent as its characters", heard(q, 12));

    // A token the server does not accept.
    const bad = opened() catch return 20;
    say(bad, "27080000000400020000006e6f");
    var wrong = db.config();
    wrong.timeout_ms = 0;
    wrong.token = "nope";
    check("a token the server refuses", attaches(bad.client, wrong));

    // A handshake the server turns away: not accepted, with a reason.
    const old = pair() catch return 21;
    say(old, "00010001");
    var plain = db.config();
    plain.timeout_ms = 0;
    check("a handshake the server turns away", attaches(old.client, plain));

    // Silence. The poller is the only clock W# has, and this is what it buys:
    // without it this call would never return.
    const quiet = opened() catch return 22;
    var brief = db.config();
    brief.timeout_ms = 150;
    const waiting = db.attach(quiet.client, brief) catch return 23;
    const ignored = heard(quiet, 9);
    check("silence, until the timeout", asks(waiting, "get t"));
    return 0;
}

fn attaches(s: net.Socket, cfg: db.Config) bool {
    const c = db.attach(s, cfg) catch return false;
    return true;
}

fn starts(c: db.Conn, statement: str) bool {
    const cur = db.cursor(c, statement) catch return false;
    return true;
}

fn asks(c: db.Conn, statement: str) bool {
    const a = db.query(c, statement) catch return false;
    return true;
}
