// An `f64` out of the eight bytes that spell it.
//
// The protocol sends a float as its bit pattern rather than as digits, so that
// NaN and both infinities survive the trip and no value changes meaning by
// being sent.
//
// This used to be ninety lines of arithmetic. W# had no way to reinterpret
// those bits -- `f64(x)` converts a *value*, not a representation -- so the
// number was rebuilt out of sign, exponent and fraction, with a hand-rolled
// `ldexp` scaling it by halving and doubling. That was exact, and the argument
// for why filled a screen. `bits.f64_from_bits` is the same answer as one
// instruction, and it is what this driver asked the language for.
//
// The file stays because the name is the one the codec reads at, and because
// `tests/ieee.ws` is a page of transcribed IEEE-754 bit patterns that is worth
// keeping pointed at whatever produces the number -- it checks the builtin now.
//
// One thing changed for the better: a NaN keeps its payload bits. The old
// decoder had no way to construct one and handed back the canonical NaN for
// every input, which was a real if narrow loss.
//
// This is decode-only. No client-to-server message carries a value, so the
// driver never has to spell a float on the wire and there is no encoder to
// keep honest.
const bits = @import("std/bits");

/// The `f64` whose little-endian bit pattern is `b`.
///
/// The endianness is the caller's business: `wire.u64le` is what reads the
/// eight bytes in the order the protocol writes them, and this takes the
/// number that comes out.
pub fn from_bits(b: u64) f64 {
    return bits.f64_from_bits(b);
}
