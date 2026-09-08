// UTF-8, validated.
//
// `docs/PROTOCOL.md` is normative that invalid UTF-8 in a `Text` field is an
// error and not a replacement character -- "almost-right text is the failure
// that survives", which is the same reasoning the server's SQLite reader
// applies to unpaired surrogates. So a `str` this driver hands to a caller has
// been checked, and one it could not check is an `error.BadUtf8` rather than a
// string with a question mark in it.
//
// Written here because W# has none: `str` is arbitrary bytes rather than text,
// there is no character type, and the only UTF-8 encoder in the whole tree is
// private inside `std/toml`, for `\uXXXX` escapes.
//
// The ranges below are RFC 3629's, not the original UTF-8's. The three things
// that separates are what a lenient decoder gets wrong: an overlong form (a
// code point spelled in more bytes than it needs, which is how a `/` sneaks
// past a filter looking for one), a surrogate half (`D800..DFFF`, which is
// UTF-16's business and not a code point), and anything above `U+10FFFF`.

/// Whether `b[at..at+n]` is well-formed UTF-8.
pub fn valid(b: []u8, at: i64, n: i64) bool {
    const end = at + n;
    var i = at;
    while (i < end) {
        const lead = i64(b[i]);

        // ASCII, which is most of every protocol.
        if (lead < 0x80) {
            i += 1;
            continue;
        }

        // How many bytes follow, and what the lead byte contributes. `C0` and
        // `C1` are missing on purpose: the only code points they can begin are
        // overlong spellings of ASCII, so they are never valid anywhere.
        var need = 0;
        var point = 0;
        if (lead >= 0xc2 and lead <= 0xdf) {
            need = 1;
            point = lead & 0x1f;
        } else if (lead >= 0xe0 and lead <= 0xef) {
            need = 2;
            point = lead & 0x0f;
        } else if (lead >= 0xf0 and lead <= 0xf4) {
            need = 3;
            point = lead & 0x07;
        } else {
            return false;
        }

        // The continuations have to be there before they are read.
        if (i + need >= end) { return false; }

        var j = 1;
        while (j <= need) : (j += 1) {
            const cont = i64(b[i + j]);
            if (cont < 0x80 or cont > 0xbf) { return false; }
            point = (point << 6) | (cont & 0x3f);
        }

        // What the sequence spells has to be what that many bytes are for.
        if (need == 2 and point < 0x800) { return false; }
        if (need == 3 and point < 0x10000) { return false; }
        if (point >= 0xd800 and point <= 0xdfff) { return false; }
        if (point > 0x10ffff) { return false; }

        i += need + 1;
    }
    return true;
}
