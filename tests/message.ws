// Every message body the server can send, and the four the client sends back.
//
// Bodies are transcribed from the message table in `docs/PROTOCOL.md`. The
// caps are checked at the boundary rather than somewhere near it, because they
// are normative: two implementations that disagree about them disagree about
// which frames are legal.
// expect: 110d00000009000000676574207573657273
// expect: 120d00000009000000676574207573657273
// expect: 100700000003000000616263
// expect: 1300000000
// expect: ok
// expect: put 2
// expect: kind of a count: 2
// expect: verb and total: put 2
// expect: id
// expect: name
// expect: no columns at all: true
// expect: 1|a
// expect: 2|bb
// expect: first line
// expect: second line
// expect: boom
// expect: kind of a failure: 5
// expect: code of a failure: 5
// expect: a failure says so: true
// expect: an answer that is not a failure: false
// expect: asking an answer for what it does not hold: false
// expect: an empty body that is empty: true
// expect: an empty body that is not: false
// expect: more lines than MAX_LINES: false
// expect: exactly MAX_LINES: true
// expect: more rows than MAX_ROWS_PER_BATCH: false
// expect: more columns than MAX_VALUES_PER_ROW: false
// expect: a count body with bytes left over: false
const array = @import("std/array");
const bytes = @import("std/bytes");
const text = @import("std/str");
const message = @import("../src/message.ws");
const wire = @import("../src/wire.ws");

fn hex(h: str) []u8 { return bytes.from_hex(h) catch bytes.new(0); }

fn check(label: str, v: bool) void {
    if (v) { print(text.concat(label, ": true")); } else { print(text.concat(label, ": false")); }
    return;
}

fn main() i64 {
    // What the client sends. A statement carries its own length inside the
    // body even though the frame header already gave one -- the redundancy is
    // deliberate, and is the mistake the specification says a client is most
    // likely to make.
    print(bytes.to_hex(message.query_frame("get users", false)));
    print(bytes.to_hex(message.query_frame("get users", true)));
    print(bytes.to_hex(message.auth_frame("abc")));
    print(bytes.to_hex(message.close_frame()));

    print(message.render(message.ok_answer()));

    // Count: a text verb and a u64.
    const counted = message.read_count(hex("030000007075740200000000000000")) catch return 1;
    print(message.render(counted));
    print(text.concat("kind of a count: ", text.from_int(message.kind(counted))));
    print(text.concat(text.concat("verb and total: ",
        message.verb_of(counted) catch "?"), text.concat(" ",
        text.from_uint(message.total_of(counted) catch 0))));

    // RowsBegin: a count of names and that many.
    const names = message.read_columns(hex("02000000020000006964040000006e616d65")) catch return 1;
    var i = 0;
    while (i < array.len(names)) : (i += 1) { print(names[i]); }
    check("no columns at all", array.len(message.read_columns(hex("00000000")) catch return 1) == 0);

    // RowBatch: a count of rows, each a count of values and that many.
    const batch = message.read_batch(hex("02000000020000000301000000000000000501000000610200000003020000000000000005020000006262")) catch return 1;
    print(message.render(message.rows_answer(names, batch)));

    const lines = message.read_lines(hex("020000000a0000006669727374206c696e650b0000007365636f6e64206c696e65")) catch return 1;
    print(message.render(message.lines_answer(lines)));

    // Error: a u16 code and a message. The code is the contract; the sentence
    // beside it is for people.
    const bad = message.read_failed(hex("050004000000626f6f6d")) catch return 1;
    print(message.render(bad));
    print(text.concat("kind of a failure: ", text.from_int(message.kind(bad))));
    print(text.concat("code of a failure: ", text.from_int(message.code_of(bad) catch -1)));
    check("a failure says so", message.failed(bad));
    check("an answer that is not a failure", message.failed(counted));

    // A field cannot be read through the supertype, so this is how asking the
    // wrong question is answered.
    check("asking an answer for what it does not hold", reads_lines(counted));

    check("an empty body that is empty", empty(""));
    check("an empty body that is not", empty("00"));

    check("more lines than MAX_LINES", reads_lines_body("01000100"));
    check("exactly MAX_LINES", counts_at_cap());
    check("more rows than MAX_ROWS_PER_BATCH", reads_batch_body("01000100"));
    check("more columns than MAX_VALUES_PER_ROW", reads_columns_body("01100000"));

    check("a count body with bytes left over", reads_count("03000000707574020000000000000000"));
    return 0;
}

fn empty(h: str) bool {
    message.read_empty(hex(h)) catch return false;
    return true;
}

fn reads_lines(a: message.Answer) bool {
    const v = message.lines_of(a) catch return false;
    return true;
}

fn reads_lines_body(h: str) bool {
    const v = message.read_lines(hex(h)) catch return false;
    return true;
}

fn reads_batch_body(h: str) bool {
    const v = message.read_batch(hex(h)) catch return false;
    return true;
}

fn reads_columns_body(h: str) bool {
    const v = message.read_columns(hex(h)) catch return false;
    return true;
}

fn reads_count(h: str) bool {
    const v = message.read_count(hex(h)) catch return false;
    return true;
}

/// A count exactly at the cap is legal; it is the one above that is not. The
/// body declares 65536 lines and supplies none, so this stops at `Truncated`
/// rather than `TooLarge` -- which is the distinction being checked.
fn counts_at_cap() bool {
    const r = wire.reader(hex("00000100"));
    const n = wire.count(r, wire.MAX_LINES) catch return false;
    return n == wire.MAX_LINES;
}
