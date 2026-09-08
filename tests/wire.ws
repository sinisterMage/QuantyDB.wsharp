// The frame format and the little-endian primitives under it.
//
// The expected bytes are transcribed from `docs/PROTOCOL.md` rather than
// produced by this driver, which is the only way this test can catch the
// driver being self-consistently wrong.
// expect: 5155414e5459010000
// expect: hello is nine bytes: true
// expect: 11020000006869
// expect: 1300000000
// expect: a frame is five bytes plus its body: true
// expect: 7
// expect: 258
// expect: 65535
// expect: -1
// expect: 18446744073709551615
// expect: hi
// expect: beef
// expect: read to the end: true
// expect: le16 round trip: true
// expect: a field past the end of the body: false
// expect: a length past the end of the body: false
// expect: bytes left over: false
// expect: invalid utf-8 in a text field: false
// expect: a count above its cap: false
// expect: a count at its cap: true
const array = @import("std/array");
const bytes = @import("std/bytes");
const text = @import("std/str");
const wire = @import("../src/wire.ws");

fn hex(h: str) []u8 { return bytes.from_hex(h) catch bytes.new(0); }

fn check(label: str, v: bool) void {
    if (v) { print(text.concat(label, ": true")); } else { print(text.concat(label, ": false")); }
    return;
}

fn main() i64 {
    // The handshake. Nine bytes: "QUANTY", the version little-endian, and a
    // reserved zero.
    const opening = wire.hello(wire.VERSION);
    print(bytes.to_hex(opening));
    check("hello is nine bytes", array.len(opening) == wire.HELLO_LEN);

    // A frame: the type byte, a u32 length, the body.
    const q = wire.frame(wire.T_QUERY, bytes.of("hi"));
    print(bytes.to_hex(q));
    print(bytes.to_hex(wire.frame(wire.T_CLOSE, bytes.new(0))));
    check("a frame is five bytes plus its body", array.len(q) == wire.HEADER_LEN + 2);

    // Every width a body can hold, read in order out of one.
    const r = wire.reader(hex("070201ffff0000ffffffffffffffff02000000686902000000beef"));
    print_int(wire.byte(r) catch return 1);
    print_int(wire.u16le(r) catch return 1);
    print_int(wire.u32le(r) catch return 1);
    // The same eight bytes read at each signedness: all ones is -1 signed and
    // the largest u64 unsigned, which is what two's complement means.
    const at = r.at;
    print_int(wire.i64le(r) catch return 1);
    r.at = at;
    print_uint(wire.u64le(r) catch return 1);
    print(wire.utf8_text(r) catch return 1);
    print(bytes.to_hex(wire.blob(r) catch return 1));
    check("read to the end", ends(r));

    check("le16 round trip", round_trip(0) and round_trip(1) and round_trip(513)
        and round_trip(65535));

    // The refusals. Each is a body a fuzzer can produce, and each has to be an
    // error rather than a panic or a partial answer.
    check("a field past the end of the body", reads_u32("0102"));
    check("a length past the end of the body", reads_text("0500000068"));
    check("bytes left over", reads_byte_then_ends("0101"));
    check("invalid utf-8 in a text field", reads_text("01000000ff"));

    // Counts are capped by the protocol and not merely by the frame: 4096
    // values to a row, and 4097 is a protocol error.
    check("a count above its cap", reads_count("01100000"));
    check("a count at its cap", reads_count("00100000"));
    return 0;
}

fn ends(r: wire.Reader) bool {
    wire.done(r) catch return false;
    return true;
}

fn round_trip(v: i64) bool {
    const b = bytes.new(2);
    wire.put_le16(b, 0, v);
    return wire.le16(b, 0) == v;
}

fn reads_u32(h: str) bool {
    const r = wire.reader(hex(h));
    const v = wire.u32le(r) catch return false;
    return true;
}

fn reads_text(h: str) bool {
    const r = wire.reader(hex(h));
    const v = wire.utf8_text(r) catch return false;
    return true;
}

fn reads_count(h: str) bool {
    const r = wire.reader(hex(h));
    const v = wire.count(r, wire.MAX_VALUES_PER_ROW) catch return false;
    return true;
}

fn reads_byte_then_ends(h: str) bool {
    const r = wire.reader(hex(h));
    const v = wire.byte(r) catch return false;
    wire.done(r) catch return false;
    return true;
}
