// Floats, rebuilt from the eight bytes that spell them.
//
// The bit patterns here were not produced by this driver. They are what the
// IEEE-754 double encoding says, transcribed, in the little-endian order the
// wire uses -- so a bug in `ieee.ws` shows up as a wrong number rather than as
// agreement with itself.
//
// Most of these assert an exact equality against a literal, because exactness
// is the claim: this is arithmetic standing in for a bitcast, and "close" is
// not what it is allowed to be. The values at the two ends of the range have
// no literal to compare against, so they are pinned by the properties that
// identify them instead.
// expect: 1.0
// expect: -2.5
// expect: -1.5
// expect: 0.5
// expect: 100.0
// expect: 0.1
// expect: 3.14159
// expect: 10000000000000000.0
// expect: exactly the literals: true
// expect: 0.0
// expect: -0.0
// expect: the zeroes have different signs: true
// expect: inf
// expect: -inf
// expect: NaN
// expect: a NaN is not itself: true
// expect: the largest finite is finite: true
// expect: one more doubling leaves the range: true
// expect: the smallest subnormal is above zero: true
// expect: nothing lies between it and zero: true
// expect: subnormals scale like the integers they are: true
// expect: the smallest normal is 2^52 subnormals: true
// expect: halving the smallest normal stays above zero: true
const bytes = @import("std/bytes");
const text = @import("std/str");
const ieee = @import("../src/ieee.ws");

/// The `f64` whose little-endian bit pattern `hex` spells.
fn of(hex: str) f64 {
    const b = bytes.from_hex(hex) catch return 0.0;
    return ieee.from_bits(bytes.le64(b, 0));
}

fn check(label: str, ok: bool) void {
    if (ok) { print(text.concat(label, ": true")); } else { print(text.concat(label, ": false")); }
    return;
}

fn main() i64 {
    // Ordinary values, printed. `print_float` gives a whole value one decimal
    // place, which is the server's rendering too.
    print_float(of("000000000000f03f"));
    print_float(of("00000000000004c0"));
    print_float(of("000000000000f8bf"));
    print_float(of("000000000000e03f"));
    print_float(of("0000000000005940"));
    print_float(of("9a9999999999b93f"));
    print_float(of("6e861bf0f9210940"));
    print_float(of("0080e03779c34143"));

    // The same values held against literals. Equality on an `f64` is exact, so
    // this is the real assertion and the printing above is its readable half.
    check("exactly the literals", of("000000000000f03f") == 1.0
        and of("00000000000004c0") == -2.5
        and of("000000000000f8bf") == -1.5
        and of("000000000000e03f") == 0.5
        and of("0000000000005940") == 100.0
        and of("9a9999999999b93f") == 0.1
        and of("0080e03779c34143") == 10000000000000000.0);

    // Both zeroes. They print differently and compare equal, which is what
    // IEEE-754 says -- so the division is what tells them apart: one over zero
    // is an infinity carrying the zero's sign.
    print_float(of("0000000000000000"));
    print_float(of("0000000000000080"));
    check("the zeroes have different signs",
        1.0 / of("0000000000000000") > 0.0 and 1.0 / of("0000000000000080") < 0.0);

    // The three values that are not numbers.
    print_float(of("000000000000f07f"));
    print_float(of("000000000000f0ff"));
    print_float(of("000000000000f87f"));
    const nan = of("000000000000f87f");
    check("a NaN is not itself", nan != nan);

    // The largest finite double: it has not left the range, and one more
    // doubling does.
    const huge = of("ffffffffffffef7f");
    check("the largest finite is finite", huge - huge == 0.0 and huge > 0.0);
    check("one more doubling leaves the range", huge * 2.0 > huge and huge * 2.0 == huge * 4.0);

    // The smallest subnormal: not zero, and with nothing between it and zero.
    const tiny = of("0100000000000000");
    check("the smallest subnormal is above zero", tiny > 0.0);
    check("nothing lies between it and zero", tiny * 0.5 == 0.0);

    // Which is the property the step-by-step halving in `ldexp` had to
    // preserve: three of them is the pattern with a three in it.
    check("subnormals scale like the integers they are", of("0300000000000000") == tiny * 3.0);

    // The boundary between subnormal and normal.
    const small = of("0000000000001000");
    check("the smallest normal is 2^52 subnormals", small == tiny * 4503599627370496.0);
    check("halving the smallest normal stays above zero",
        small * 0.5 > 0.0 and small * 0.5 < small);
    return 0;
}
