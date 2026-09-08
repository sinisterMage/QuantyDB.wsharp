// A value, as it crosses the socket.
//
// Six tags, and a W# type for each. The shape is `std/toml`'s: an empty base
// struct, one subtype per case, and overload sets that dispatch on which
// subtype an object actually is. W# has no tagged union of its own, and this
// is the language's answer -- a struct's identity is a type id, dispatch is one
// subtract and one unsigned compare on it, and a case that has been forgotten
// falls to the base overload rather than being silently misread.
//
// The base overloads below are the ones a caller reaches by asking a value for
// something it is not. They answer `error.BadType` rather than a default,
// because a null read as a zero is the bug this whole layer exists to prevent.
//
// **This is decode-only, on purpose.** Every client-to-server message carries a
// token or a statement -- never a value -- so nothing here is ever written to
// the wire. The constructors exist for tests and for callers assembling a value
// of their own, not for an encoder.
const array = @import("std/array");
const bytes = @import("std/bytes");
const text = @import("std/str");
const ieee = @import("./ieee.ws");
const wire = @import("./wire.ws");

pub const Value = struct { };
pub const Null = struct : Value { };
pub const Bool = struct : Value { b: bool };
pub const Int = struct : Value { n: i64 };
pub const Float = struct : Value { f: f64 };
pub const Text = struct : Value { s: str };

/// The protocol's `Bytes`. Named `Blob` so that the type and the module
/// `std/bytes` do not read as the same thing at a glance.
pub const Blob = struct : Value { b: []u8 };

// ---------------------------------------------------------------------------
// Constructors
// ---------------------------------------------------------------------------
//
// These answer `Value` rather than the subtype, and they are a convenience
// now. They were not: W# coerced a subtype to its supertype, and a value into
// an `!T`, and would not do both in one step -- so `return Null{ }` from a
// function declared `!Value` was a type error and this was the bridge. A
// coercion is a sequence of steps now, so `decode` could return the subtypes
// straight out; these stay because naming the case reads better at a call site
// than a struct literal does, and because they are the public surface.

pub fn null_value() Value { return Null{ }; }
pub fn bool_value(v: bool) Value { return Bool{ .b = v }; }
pub fn int_value(v: i64) Value { return Int{ .n = v }; }
pub fn float_value(v: f64) Value { return Float{ .f = v }; }
pub fn text_value(v: str) Value { return Text{ .s = v }; }
pub fn blob_value(v: []u8) Value { return Blob{ .b = v }; }

// ---------------------------------------------------------------------------
// Asking what one is
// ---------------------------------------------------------------------------

/// The wire tag of `v`, or zero for a value of no known kind.
pub fn tag(v: Value) i64 { return 0; }
pub fn tag(v: Null) i64 { return wire.V_NULL; }
pub fn tag(v: Bool) i64 { return wire.V_BOOL; }
pub fn tag(v: Int) i64 { return wire.V_INT; }
pub fn tag(v: Float) i64 { return wire.V_FLOAT; }
pub fn tag(v: Text) i64 { return wire.V_TEXT; }
pub fn tag(v: Blob) i64 { return wire.V_BYTES; }

pub fn is_null(v: Value) bool { return false; }
pub fn is_null(v: Null) bool { return true; }

// ---------------------------------------------------------------------------
// Reading one out
// ---------------------------------------------------------------------------
//
// Strict: an `Int` is not an `f64` here, and a `Bool` is not a one. A driver
// that widens quietly is a driver that turns a schema change into a wrong
// number instead of an error, and the caller who wants the widening can write
// `f64(try as_int(v))` and be seen doing it.

pub fn as_bool(v: Value) !{BadType}bool { return error.BadType; }
pub fn as_bool(v: Bool) !{BadType}bool { return v.b; }

pub fn as_int(v: Value) !{BadType}i64 { return error.BadType; }
pub fn as_int(v: Int) !{BadType}i64 { return v.n; }

pub fn as_float(v: Value) !{BadType}f64 { return error.BadType; }
pub fn as_float(v: Float) !{BadType}f64 { return v.f; }

pub fn as_text(v: Value) !{BadType}str { return error.BadType; }
pub fn as_text(v: Text) !{BadType}str { return v.s; }

pub fn as_blob(v: Value) !{BadType}[]u8 { return error.BadType; }
pub fn as_blob(v: Blob) !{BadType}[]u8 { return v.b; }

// ---------------------------------------------------------------------------
// Rendering
// ---------------------------------------------------------------------------
//
// The same rendering the server's own `render_value` does, so that what this
// driver prints for a statement is what `quantydb run` prints for it: null,
// `true`/`false`, a bare integer, a float with its decimal point, text as
// itself, and bytes as `x"<hex>"`.
//
// Floats need one adjustment to get there. The server writes a float with
// Rust's `{:?}`, which gives a whole value a `.0` so it cannot be mistaken for
// an integer; `str.from_float` is `{}`, which does not. So `integral` below
// asks whether what came back is all digits, and puts the `.0` on when it is --
// which is exactly what `print_float` does, for the same reason.
//
// One difference is left and it is W#'s rather than the protocol's: `{:?}`
// falls back to exponent notation at extreme magnitudes and W# has no such
// notation, so a float near the top or bottom of the range comes out as its
// full decimal expansion where the server would write `1e308`. The value is
// identical; only the spelling differs.

pub fn render(v: Value) str { return "?"; }
pub fn render(v: Null) str { return "null"; }
pub fn render(v: Int) str { return text.from_int(v.n); }
pub fn render(v: Text) str { return v.s; }

pub fn render(v: Float) str {
    const s = text.from_float(v.f);
    if (integral(s)) { return text.concat(s, ".0"); }
    return s;
}

/// Whether `s` is a run of digits with an optional leading minus -- which is
/// what a whole float renders as, and what `inf`, `-inf` and `NaN` do not.
fn integral(s: str) bool {
    var i = 0;
    if (text.len(s) > 0 and text.byte_at(s, 0) == 45) { i = 1; }
    if (i >= text.len(s)) { return false; }
    while (i < text.len(s)) : (i += 1) {
        const c = text.byte_at(s, i);
        if (c < 48 or c > 57) { return false; }
    }
    return true;
}

pub fn render(v: Bool) str {
    if (v.b) { return "true"; }
    return "false";
}

pub fn render(v: Blob) str {
    return text.concat(text.concat("x\"", bytes.to_hex(v.b)), "\"");
}

// ---------------------------------------------------------------------------
// Decoding
// ---------------------------------------------------------------------------

/// One value: a one byte tag and its payload.
///
/// Every length inside is bounded by what is left of the body, which is itself
/// bounded by `MAX_BODY`, so nothing here can be made to allocate more than a
/// frame's worth however the bytes are arranged.
pub fn decode(r: wire.Reader) !Value {
    const t = try wire.byte(r);

    if (t == wire.V_NULL) { return null_value(); }

    if (t == wire.V_BOOL) {
        const b = try wire.byte(r);
        // "1 byte, 0 or 1; any other byte is an error" -- so a 2 is a protocol
        // error and not a truthy value.
        if (b > 1) { return error.BadValue; }
        return bool_value(b == 1);
    }

    if (t == wire.V_INT) { return int_value(try wire.i64le(r)); }

    // Bits rather than digits, so that NaN and both infinities survive.
    if (t == wire.V_FLOAT) { return float_value(ieee.from_bits(try wire.u64le(r))); }

    if (t == wire.V_TEXT) { return text_value(try wire.utf8_text(r)); }

    if (t == wire.V_BYTES) { return blob_value(try wire.blob(r)); }

    return error.BadTag;
}

/// A `u32` count of values and that many of them -- one row.
///
/// An array rather than a `list.List`, because the width is known before the
/// first value is read and a list would grow into a capacity it does not need.
/// It used to be for a worse reason as well: `for` over a list of structs did
/// not resolve the loop variable's type, so the obvious loop got the wrong
/// overload of `render` with no diagnostic. That is fixed, and either would be
/// correct now.
pub fn decode_row(r: wire.Reader) ![]Value {
    const width = try wire.count(r, wire.MAX_VALUES_PER_ROW);
    var out: []Value = array.new(width);
    var i = 0;
    while (i < width) : (i += 1) {
        out[i] = try decode(r);
    }
    return out;
}
