// UTF-8, and the four ways of spelling something that is not it.
//
// The rejections are the point. A validator that accepts everything valid is
// half a validator; what makes this one worth having is that an overlong form,
// a surrogate half and a code point above the range are refused, because those
// are the sequences that survive a lenient decoder and mean something
// different at the other end.
// expect: ascii: true
// expect: two bytes: true
// expect: three bytes: true
// expect: four bytes: true
// expect: all of them at once: true
// expect: empty: true
// expect: a bare continuation byte: false
// expect: a lead byte with nothing after it: false
// expect: a lead byte with too little after it: false
// expect: a continuation that is not one: false
// expect: 0xff, which is in no sequence: false
// expect: 0xc0, an overlong two-byte NUL: false
// expect: 0xc1, the other overlong lead: false
// expect: an overlong three-byte form: false
// expect: an overlong four-byte form: false
// expect: a surrogate half, U+D800: false
// expect: the top surrogate, U+DFFF: false
// expect: U+110000, one past the last code point: false
// expect: 0xf5, a lead for a range that does not exist: false
// expect: the last valid code point, U+10FFFF: true
// expect: the byte before the first surrogate, U+D7FF: true
// expect: the byte after the last surrogate, U+E000: true
const bytes = @import("std/bytes");
const array = @import("std/array");
const text = @import("std/str");
const utf8 = @import("../src/utf8.ws");

fn ok(hex: str) bool {
    const b = bytes.from_hex(hex) catch return false;
    return utf8.valid(b, 0, array.len(b));
}

fn check(label: str, v: bool) void {
    if (v) { print(text.concat(label, ": true")); } else { print(text.concat(label, ": false")); }
    return;
}

fn main() i64 {
    check("ascii", ok("41"));
    check("two bytes", ok("c3a9"));                    // U+00E9
    check("three bytes", ok("e282ac"));                // U+20AC
    check("four bytes", ok("f09d849e"));               // U+1D11E
    check("all of them at once", ok("41c3a9e282acf09d849e"));
    check("empty", ok(""));

    check("a bare continuation byte", ok("80"));
    check("a lead byte with nothing after it", ok("c3"));
    check("a lead byte with too little after it", ok("e282"));
    check("a continuation that is not one", ok("c341"));
    check("0xff, which is in no sequence", ok("ff"));

    // Overlong forms: a code point written in more bytes than it needs. C0 and
    // C1 can begin nothing else, so they are refused as lead bytes outright.
    check("0xc0, an overlong two-byte NUL", ok("c080"));
    check("0xc1, the other overlong lead", ok("c1bf"));
    check("an overlong three-byte form", ok("e08080"));
    check("an overlong four-byte form", ok("f0808080"));

    // Surrogates are UTF-16's business and are not code points.
    check("a surrogate half, U+D800", ok("eda080"));
    check("the top surrogate, U+DFFF", ok("edbfbf"));

    check("U+110000, one past the last code point", ok("f4908080"));
    check("0xf5, a lead for a range that does not exist", ok("f5808080"));

    // The values immediately outside each excluded range are valid, which is
    // what says the bounds are in the right place rather than merely strict.
    check("the last valid code point, U+10FFFF", ok("f48fbfbf"));
    check("the byte before the first surrogate, U+D7FF", ok("ed9fbf"));
    check("the byte after the last surrogate, U+E000", ok("ee8080"));
    return 0;
}
