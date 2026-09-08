// The QuantyDB wire format, version 1: its constants, and the little-endian
// primitives `std/bytes` does not have.
//
// Everything in this protocol is little-endian and `std/bytes` mostly is not:
// its `Buf` appenders (`put_u16`, `put_u24`, `put_u32`) are all big-endian,
// because TLS and DER are, and it has `le32` and `le64` accessors but no
// `le16`. Reaching for one of those by mistake would produce a frame the
// server rejects for no visible reason, so the little-endian half lives here
// and nothing below this file touches `bytes.put_u16` and its neighbours.
//
// The reader is the other half of the module's job. A body arrives as a `[]u8`
// whose length the frame header already gave, and every field inside it is
// bounds-checked against that length rather than trusted: the numbers came
// from the network, and the specification is explicit that a decoder handed
// nonsense answers with an error rather than panicking. `Reader` is what makes
// that the default -- there is no way to read a field out of a body except
// through a call that can say `error.Truncated`.
const array = @import("std/array");
const bytes = @import("std/bytes");
const text = @import("std/str");
const utf8 = @import("./utf8.ws");

/// The protocol version this driver speaks.
pub const VERSION = 1;

/// The six bytes a conversation opens with.
pub const MAGIC = "QUANTY";

pub const HELLO_LEN = 9;
pub const SERVER_HELLO_LEN = 4;
pub const HEADER_LEN = 5;

/// A frame body is at most 16 MiB. This is the whole reason a decoder may
/// allocate from a length field at all: the number arrives from the network,
/// so it is either capped before it reaches an allocator or it is a way to ask
/// for arbitrary memory.
pub const MAX_BODY = 16777216;

// Element caps. A length field says how many *bytes* follow and the frame cap
// alone bounds it; a count field says how many *structures* follow, and a
// structure costs more in memory than it does on the wire. These are part of
// the format rather than a local defence -- two implementations that disagree
// about them disagree about which frames are legal.
pub const MAX_VALUES_PER_ROW = 4096;
pub const MAX_ROWS_PER_BATCH = 65536;
pub const MAX_LINES = 65536;

// Client to server.
pub const T_AUTH = 0x10;
pub const T_QUERY = 0x11;
pub const T_QUERY_SQL = 0x12;
pub const T_CLOSE = 0x13;

// Server to client.
pub const T_READY = 0x20;
pub const T_OK = 0x21;
pub const T_COUNT = 0x22;
pub const T_ROWS_BEGIN = 0x23;
pub const T_ROW_BATCH = 0x24;
pub const T_ROWS_END = 0x25;
pub const T_LINES = 0x26;
pub const T_ERROR = 0x27;

// Value tags.
pub const V_NULL = 0x01;
pub const V_BOOL = 0x02;
pub const V_INT = 0x03;
pub const V_FLOAT = 0x04;
pub const V_TEXT = 0x05;
pub const V_BYTES = 0x06;

// Why a handshake was refused. Four bytes is all an old client can be relied
// on to parse, so this is the one thing it can always print.
pub const REFUSED_TOO_OLD = 0x01;
pub const REFUSED_TOO_NEW = 0x02;
pub const REFUSED_BAD_MAGIC = 0x03;

// Error codes. The code is the contract; the message beside it is for people.
pub const E_PROTOCOL = 0x0001;
pub const E_VERSION = 0x0002;
pub const E_UNAUTHENTICATED = 0x0003;
pub const E_AUTH_FAILED = 0x0004;
pub const E_PARSE = 0x0005;
pub const E_EXECUTION = 0x0006;
pub const E_WRITE_QUEUE = 0x0007;
pub const E_SHUTTING_DOWN = 0x0008;

// ---------------------------------------------------------------------------
// Little-endian words
// ---------------------------------------------------------------------------

/// The little-endian 16-bit integer at `at`.
///
/// Answered as an `i64` rather than a `u16`, which is `bytes.be16`'s deviation
/// and for its reason: every one of these is a length, a version or a code,
/// all of which are compared against `i64` constants.
pub fn le16(b: []u8, at: i64) i64 {
    return i64(b[at]) | (i64(b[at + 1]) << 8);
}

pub fn put_le16(b: []u8, at: i64, v: i64) void {
    b[at] = u8(v);
    b[at + 1] = u8(v >> 8);
    return;
}

// ---------------------------------------------------------------------------
// Appending
// ---------------------------------------------------------------------------

pub fn put_u16le(b: bytes.Buf, v: i64) void {
    bytes.put_u8(b, v);
    bytes.put_u8(b, v >> 8);
    return;
}

pub fn put_u32le(b: bytes.Buf, v: i64) void {
    bytes.put_u8(b, v);
    bytes.put_u8(b, v >> 8);
    bytes.put_u8(b, v >> 16);
    bytes.put_u8(b, v >> 24);
    return;
}

/// A `u32` length and that many bytes -- the shape every variable length field
/// in this protocol is written in, without exception. The specification says
/// so and means it: a statement carries its own length even though the frame
/// header already gave one, so that a decoder has one rule rather than one
/// rule and an exception.
pub fn put_text(b: bytes.Buf, s: str) void {
    put_u32le(b, text.len(s));
    bytes.put_str(b, s);
    return;
}

pub fn put_blob(b: bytes.Buf, v: []u8) void {
    put_u32le(b, array.len(v));
    bytes.put_all(b, v);
    return;
}

/// The nine bytes a client opens with. Unframed, and fixed for all time: the
/// handshake is how a version is agreed, so it cannot itself be versioned.
pub fn hello(version: i64) []u8 {
    const b = bytes.buf(HELLO_LEN);
    bytes.put_str(b, MAGIC);
    put_u16le(b, version);
    bytes.put_u8(b, 0);
    return bytes.taken(b);
}

/// One frame: a type byte, a `u32` body length, and the body.
///
/// The body is always complete before this is called, so there is no length to
/// patch in afterwards and the whole frame is one buffer. That is worth
/// keeping: W# exposes no `setsockopt`, so `TCP_NODELAY` cannot be set and
/// Nagle is always on. A request written as a header and then a body is the
/// two-write shape a delayed ACK stalls; written as one it is the ordinary
/// request-and-response pattern Nagle leaves alone.
pub fn frame(kind: i64, body: []u8) []u8 {
    const b = bytes.buf(HEADER_LEN + array.len(body));
    bytes.put_u8(b, kind);
    put_u32le(b, array.len(body));
    bytes.put_all(b, body);
    return bytes.taken(b);
}

// ---------------------------------------------------------------------------
// Reading a body
// ---------------------------------------------------------------------------

/// A walk through one message body, which is as far as anything may read.
///
/// `end` is where the body stops, and every read below checks against it. A
/// length inside a body can name more bytes than the body holds -- that is
/// exactly the frame a fuzzer sends -- and the answer is `error.Truncated`
/// rather than an index panic.
pub const Reader = struct { b: []u8, at: i64, end: i64 };

pub fn reader(b: []u8) Reader {
    return Reader{ .b = b, .at = 0, .end = array.len(b) };
}

/// How much of the body has not been read.
pub fn left(r: Reader) i64 { return r.end - r.at; }

/// That the body ended exactly where the message did.
///
/// Checked for every message rather than only some: bytes left over mean the
/// sender and this decoder disagree about the format, and finding that out on
/// the message that caused it is worth more than tolerating it.
pub fn done(r: Reader) !{Trailing}void {
    if (r.at != r.end) { return error.Trailing; }
    return;
}

pub fn byte(r: Reader) !{Truncated}i64 {
    if (left(r) < 1) { return error.Truncated; }
    const v = i64(r.b[r.at]);
    r.at += 1;
    return v;
}

pub fn u16le(r: Reader) !{Truncated}i64 {
    if (left(r) < 2) { return error.Truncated; }
    const v = le16(r.b, r.at);
    r.at += 2;
    return v;
}

pub fn u32le(r: Reader) !{Truncated}i64 {
    if (left(r) < 4) { return error.Truncated; }
    const v = i64(bytes.le32(r.b, r.at));
    r.at += 4;
    return v;
}

pub fn u64le(r: Reader) !{Truncated}u64 {
    if (left(r) < 8) { return error.Truncated; }
    const v = bytes.le64(r.b, r.at);
    r.at += 8;
    return v;
}

/// A signed 64-bit integer, which is what an `Int` value carries.
///
/// The same eight bytes as `u64le` read at the other signedness: a conversion
/// between two 64-bit types keeps every bit and only changes how the top one
/// is read, which is what two's complement means.
pub fn i64le(r: Reader) !{Truncated}i64 {
    return i64(try u64le(r));
}

/// `n` bytes, as a buffer of their own.
pub fn take(r: Reader, n: i64) !{Truncated}[]u8 {
    if (n < 0 or left(r) < n) { return error.Truncated; }
    const out = bytes.slice(r.b, r.at, r.at + n);
    r.at += n;
    return out;
}

/// A `u32` length and that many bytes, unchecked -- the protocol's `bytes`.
pub fn blob(r: Reader) !{Truncated}[]u8 {
    const n = try u32le(r);
    return try take(r, n);
}

/// A `u32` length and that many bytes of UTF-8 -- the protocol's `text`.
///
/// Validated rather than trusted, because the specification says invalid UTF-8
/// here is an error and not a replacement character.
pub fn utf8_text(r: Reader) !{Truncated, BadUtf8}str {
    const n = try u32le(r);
    if (n < 0 or left(r) < n) { return error.Truncated; }
    if (!utf8.valid(r.b, r.at, n)) { return error.BadUtf8; }
    const s = bytes.slice_str(r.b, r.at, r.at + n);
    r.at += n;
    return s;
}

/// A `u32` count, refused above the cap the protocol sets for it.
///
/// Separate from `u32le` because the caps are normative: a message declaring
/// more structures than one of them allows is a protocol error and closes the
/// connection, rather than something to try and read.
pub fn count(r: Reader, cap: i64) !{Truncated, TooLarge}i64 {
    const n = try u32le(r);
    if (n > cap) { return error.TooLarge; }
    return n;
}
