# quantydb/client

A driver for [QuantyDB](https://github.com/QuantyRoot/QuantyDatabase), written in
pure [W#](https://wsharp.io). It speaks the wire protocol in that project's
`docs/PROTOCOL.md`, version 1, and depends on nothing but `std`.

Pure W# is not a constraint here so much as the only option: W# has no FFI, so
there was never a C client library to bind. It is also enough. The protocol is
plain TCP with a nine-byte handshake, a five-byte frame header and six value
tags, and `std/net` already has the record-oriented socket calls a wire format
wants.

```wsharp
const db = @import("quantydb/client");

fn main() i64 {
    const c = db.connect("127.0.0.1", 7878) catch return 1;

    const cur = db.cursor(c, "get users { name, score } where score > 10") catch return 2;
    print(text.join(db.columns(cur), " | "));
    while (db.next_row(cur) catch return 3) |r| {
        print(db.render(r.values[0]));
    }

    db.close(c);
    return 0;
}
```

## Installing

```sh
ingot add quantydb/client --path ../QuantyDB.wsharp
ingot resolve && ingot install
```

Then `@import("quantydb/client")`. There is a runnable example in
`examples/hello.ws`.

**Needs W# 0.1.2 or newer.** `ingot.toml` has no field for saying so, so it is
said here: the value decoder uses `bits.f64_from_bits`, and `next_row` answers
`!?Row`, neither of which 0.1.1 could compile. Both arrived because writing this
driver is what found them missing.

## The API

### Connecting

```wsharp
db.config() Config                                  // no token, 60s idle timeout
db.connect(host, port) !Conn
db.connect_with(host, port, cfg) !Conn
db.attach(socket, cfg) !Conn                        // a socket you already have
db.close(c) void                                    // sends Close, then closes
```

`Config` is `{ token: str, timeout_ms: i64 }`. A `timeout_ms` of zero blocks
forever.

**The token goes on the wire as the characters it is printed as.** `quantydb
token <label>` prints sixty-four hexadecimal characters; those sixty-four bytes
are what `Auth` carries, not the thirty-two they spell. Decoding the hex first
produces a refusal that says nothing about why.

### Statements

```wsharp
db.query(c, statement) !Answer          // QQL, everything collected
db.query_sql(c, statement) !Answer      // the SQL front end

db.cursor(c, statement) !Cursor         // rows streamed a batch at a time
db.cursor_sql(c, statement) !Cursor
db.columns(cur) []str
db.next_row(cur) !?Row                  // the next row, or null at the end
db.advance(cur) !bool                   // the same, read out in two calls
db.row(cur) Row                         // the row advance last loaded
db.finish(cur) !Answer                  // drain the rest, and the terminal answer
```

`next_row` is the loop:

```wsharp
while (try db.next_row(cur)) |r| { print(db.render(r.values[0])); }
```

`advance` and `row` are the same state machine read out in two calls, which is
what a caller who wants the row index alongside writes anyway.

A connection carries **one statement at a time** — the protocol has no request
ids and cannot interleave answers — so a cursor must be read to its end before
the next statement goes. Sending one early is `error.RequestInFlight` rather
than a corrupted stream. Concurrency is a second connection.

### Answers

An `Answer` is one of `Ok`, `Count`, `Rows`, `Lines` or `Failed`. W# resolves a
field by the object's declared type, so a value held as an `Answer` gives up
what it holds through accessors rather than through `.field`:

```wsharp
db.kind(a) i64                  // KIND_OK, KIND_COUNT, KIND_ROWS, KIND_LINES, KIND_FAILED
db.failed(a) bool
db.verb_of(a) !str              db.total_of(a) !u64      // Count
db.columns_of(a) ![]str         db.rows_of(a) ![]Row     // Rows
db.lines_of(a) ![]str                                    // Lines
db.code_of(a) !i64              db.message_of(a) !str    // Failed
db.render(a) str                // what `quantydb connect` prints for it
```

**A statement the server refuses is an answer, not an error.** `Failed` carries
the code and the message, and the connection is still good for the next
statement — which is what the reference client does too. The `!` on these
functions is for transport and protocol faults, which are fatal to the
connection.

Error code `0x0007` (`db.E_WRITE_QUEUE`) means the statement waited for the
writer past the server's deadline and did not run. **Retrying is correct**, and
is what the code is for.

### Values

A `Value` is one of `Null`, `Bool`, `Int`, `Float`, `Text` or `Blob`, reached
the same way:

```wsharp
db.tag(v) i64                   // V_NULL … V_BYTES
db.is_null(v) bool
db.as_bool(v) !bool             db.as_int(v) !i64        db.as_float(v) !f64
db.as_text(v) !str              db.as_blob(v) ![]u8
db.render(v) str
```

The accessors are strict: an `Int` is not an `f64` here and a `Bool` is not a
one. A driver that widens quietly turns a schema change into a wrong number
rather than an error.

This driver hands out arrays everywhere (`Rows.rows` is `[]Row`, `Row.values`
is `[]Value`), so the obvious loop is the right one:

```wsharp
for (rows) |r| { ... }
for (r.values) |v| { print(db.render(v)); }
```

## Limitations

- **No connection pooling.** `net.Socket` is a transferable handle, so a pool as
  a worker-per-connection is expressible; it is not written.
- **No TLS.** QuantyDB has none — its own documentation says to keep the server
  on loopback or put wireguard, an ssh tunnel or a TLS proxy in front of it.
- **No `TCP_NODELAY`.** W# exposes no `setsockopt`. Mitigated by writing each
  request as a single frame in one `write`, which is the shape Nagle leaves
  alone; the two-write shape is what a delayed ACK stalls.
- **The timeout is an idle timeout, not a deadline.** No byte for `timeout_ms`
  is a failure; a slow answer that keeps arriving is not. `std/time` counts
  whole seconds, so this is the only promise a clock this coarse can keep. It is
  also exactly what `SO_RCVTIMEO` gives the reference client.
- **Floats of extreme magnitude render differently.** The server writes `1e308`;
  W# has no exponent notation and writes the full decimal expansion. The value
  is identical.
- **Decode only.** No client-to-server message carries a value, so there is no
  value encoder and no way to use this as a server.

## Tests

```sh
./tests/run.sh              # no network, no server
./tests/live.sh             # against a real `quantydb serve`
```

`run.sh` is the W# compiler's own contract: a case is a `.ws` program whose
header comment declares one `// expect:` line per line it should print.

The codec is written against `[]u8` and the socket is a thin layer over it, so
the format is testable offline. The fixtures are transcribed from
`docs/PROTOCOL.md` rather than generated by this driver — a shared
encoder/decoder bug would otherwise cancel itself out. `tests/session.ws` runs a
whole conversation over a loopback socket pair held in one worker, checking both
what the driver reads and, byte for byte, what it sends.

| | |
|---|---|
| `ieee.ws` | IEEE-754 decoding: exact equalities, both zeroes, subnormals, the range ends |
| `utf8.ws` | overlongs, surrogates, out-of-range code points, and the values just outside each |
| `wire.ws` | the handshake and frame bytes, every integer width, every refusal |
| `value.ws` | all six tags, the rendering, and the bodies that must not decode |
| `message.ws` | every message body, the element caps, the client frames |
| `session.ws` | handshake, auth, all five answer kinds, multi-batch streaming, a mid-result error, the timeout |

## Licence

MIT, matching QuantyDB.
