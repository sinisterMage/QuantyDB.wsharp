// An `f64` out of the eight bytes that spell it.
//
// The protocol sends a float as its bit pattern rather than as digits, so that
// NaN and both infinities survive the trip and no value changes meaning by
// being sent. W# has no way to reinterpret those bits: there is no bitcast
// builtin -- the whole native surface is one table in the compiler and nothing
// in it crosses between `f64` and an integer at the bit level -- and `f64(x)`
// converts a *value*, not a representation.
//
// So the number is rebuilt out of its three fields by arithmetic. That sounds
// like it should be approximate and it is not; the exactness argument is
// worth writing down, because it is the reason this is allowed to be the
// answer rather than a rounding hazard:
//
//   * The significand is an integer below 2^53, so `f64(i64)` on it is exact.
//   * Scaling is by halving and doubling, each of which is exact in IEEE-754
//     whenever the result is representable.
//   * Every intermediate is `m * 2^-j` with `j <= 1074` and `m` an integer, so
//     each is an integer multiple of 2^-1074 -- exactly representable even
//     after the value has fallen into the subnormal range, which is the one
//     place a step-by-step scaling could otherwise lose bits.
//   * Doubling cannot overflow, because a finite input has `m * 2^e < 2^1024`.
//
// Deliberately not `math.pow(2.0, e)`: `powf` is not guaranteed exact for
// integer exponents, and being off by one ulp here would be a value that is
// wrong in a way nothing downstream could notice.
//
// This is decode-only. No client-to-server message carries a value, so the
// driver never has to spell a float on the wire and there is no encoder to
// keep honest.

/// 1 followed by 52 zeros: the implicit bit a normal number does not store.
const HIDDEN = 4503599627370496;

/// The `f64` whose little-endian bit pattern is `bits`.
pub fn from_bits(bits: u64) f64 {
    const negative = ((bits >> 63) & 1) == 1;
    const exponent = i64((bits >> 52) & 0x7ff);
    const fraction = i64(bits & 0xfffffffffffff);

    // All ones: an infinity when there is nothing in the fraction, a NaN when
    // there is. A NaN's payload cannot be carried across -- W# offers no way
    // to construct one bit by bit -- so every NaN arrives as the one this
    // expression makes. That is a real if narrow loss, and it is documented
    // rather than hidden.
    if (exponent == 0x7ff) {
        if (fraction != 0) { return 0.0 / 0.0; }
        if (negative) { return -1.0 / 0.0; }
        return 1.0 / 0.0;
    }

    var significand = 0.0;
    var scale = 0;
    if (exponent == 0) {
        // Subnormal, and zero is the case of it with nothing set -- which is
        // why negative zero comes out right without being asked for: the
        // negation at the end is what distinguishes it.
        significand = f64(fraction);
        scale = -1074;
    } else {
        significand = f64(fraction + HIDDEN);
        scale = exponent - 1075;
    }

    const value = ldexp(significand, scale);
    if (negative) { return -value; }
    return value;
}

/// `m * 2^e`, exactly.
///
/// A loop rather than a table: the worst case is 1074 multiplications, a float
/// in a result set is not a hot path, and a loop has no constants to get
/// wrong.
fn ldexp(m: f64, e: i64) f64 {
    var value = m;
    var k = e;
    while (k > 0) : (k -= 1) { value *= 2.0; }
    while (k < 0) : (k += 1) { value *= 0.5; }
    return value;
}
