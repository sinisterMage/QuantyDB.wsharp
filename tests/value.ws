// The six value tags, decoded and rendered.
//
// The rendering is held to what the server's own `render_value` produces, so
// that what this driver prints for a statement is what `quantydb run` prints
// for the same one: `null`, `true`/`false`, a bare integer, a float that keeps
// its decimal point, text as itself, and bytes as `x"<hex>"`.
// expect: null
// expect: false
// expect: true
// expect: 7
// expect: -1
// expect: 1.0
// expect: 3.14159
// expect: hi
// expect: (empty)
// expect: x"beef"
// expect: x""
// expect: tags in order: true
// expect: null knows itself: true
// expect: nothing else claims to be null: true
// expect: reading a value as what it is: true
// expect: reading a value as what it is not: false
// expect: a bool carrying 2: false
// expect: invalid utf-8 in a text value: false
// expect: a tag the document does not define: false
// expect: an int with too few bytes: false
// expect: a row of two: 1|a
// expect: a row wider than the cap: false
const array = @import("std/array");
const bytes = @import("std/bytes");
const text = @import("std/str");
const value = @import("../src/value.ws");
const wire = @import("../src/wire.ws");

fn hex(h: str) []u8 { return bytes.from_hex(h) catch bytes.new(0); }

/// Decode exactly one value out of `h`, which must be all of it.
fn one(h: str) value.Value {
    const r = wire.reader(hex(h));
    const v = value.decode(r) catch return value.text_value("<undecodable>");
    wire.done(r) catch return value.text_value("<trailing>");
    return v;
}

/// Whether `h` is one whole, well-formed value.
fn decodes(h: str) bool {
    const r = wire.reader(hex(h));
    const v = value.decode(r) catch return false;
    wire.done(r) catch return false;
    return true;
}

fn check(label: str, v: bool) void {
    if (v) { print(text.concat(label, ": true")); } else { print(text.concat(label, ": false")); }
    return;
}

fn shown(v: value.Value) str {
    const s = value.render(v);
    if (text.len(s) == 0) { return "(empty)"; }
    return s;
}

fn main() i64 {
    print(shown(one("01")));
    print(shown(one("0200")));
    print(shown(one("0201")));
    print(shown(one("030700000000000000")));
    print(shown(one("03ffffffffffffffff")));
    print(shown(one("04000000000000f03f")));
    print(shown(one("046e861bf0f9210940")));
    print(shown(one("05020000006869")));
    print(shown(one("0500000000")));
    print(shown(one("0602000000beef")));
    print(shown(one("0600000000")));

    check("tags in order",
        value.tag(one("01")) == wire.V_NULL
        and value.tag(one("0201")) == wire.V_BOOL
        and value.tag(one("030700000000000000")) == wire.V_INT
        and value.tag(one("04000000000000f03f")) == wire.V_FLOAT
        and value.tag(one("05020000006869")) == wire.V_TEXT
        and value.tag(one("0602000000beef")) == wire.V_BYTES);

    check("null knows itself", value.is_null(one("01")));
    check("nothing else claims to be null",
        !value.is_null(one("0201")) and !value.is_null(one("030700000000000000")));

    // The accessors are strict: an `Int` is not an `f64` here and a `Bool` is
    // not a one, because a driver that widens quietly turns a schema change
    // into a wrong number rather than an error.
    check("reading a value as what it is", reads_int("030700000000000000"));
    check("reading a value as what it is not", reads_int("05020000006869"));

    check("a bool carrying 2", decodes("0202"));
    check("invalid utf-8 in a text value", decodes("0501000000ff"));
    check("a tag the document does not define", decodes("07"));
    check("an int with too few bytes", decodes("030700"));

    // A row is a count of values and that many of them.
    print(text.concat("a row of two: ", row_of("02000000030100000000000000050100000061")));
    check("a row wider than the cap", reads_row("01100000"));
    return 0;
}

fn reads_int(h: str) bool {
    const v = value.as_int(one(h)) catch return false;
    return true;
}

fn reads_row(h: str) bool {
    const r = wire.reader(hex(h));
    const vs = value.decode_row(r) catch return false;
    return true;
}

fn row_of(h: str) str {
    const r = wire.reader(hex(h));
    const vs = value.decode_row(r) catch return "<undecodable>";
    var cells: []str = array.new(array.len(vs));
    var i = 0;
    while (i < array.len(vs)) : (i += 1) { cells[i] = value.render(vs[i]); }
    return text.join(cells, "|");
}
