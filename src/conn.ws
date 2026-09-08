// A connection: the socket, the buffer in front of it, and the handshake that
// has to happen before anything else can.
//
// Three things about this protocol shape everything below.
//
// **One request is in flight at a time.** There are no request ids and no
// pipelining, so a client that sends a second statement before draining the
// first gets the answers interleaved with no way to tell which is which. The
// `busy` flag is what makes that `error.RequestInFlight` instead.
//
// **An accepted handshake is followed by an unprompted `Ready`,** whether or
// not the server wants a token. A client that does not read it finds it
// waiting as the answer to whatever it sends next, which looks like the server
// replying to the wrong message. It is read here, before anyone can send
// anything.
//
// **There is no read timeout in W#, and no `sleep`.** A blocking read on a
// server that has stopped answering waits forever, and `std/time` has one
// function that counts whole seconds. So a timeout is built out of the one
// thing that does take a number of milliseconds: a `Poller`.
//
// The socket stays *blocking* and the poller is a gate in front of it, rather
// than the other way round. Making the socket non-blocking would be the obvious
// move and it is still the wrong one here: every read and write would have to
// tell `error.WouldBlock` apart from a real failure and hand the rest on. W#
// can say that now -- a caught `e` may be returned from an `!T` function -- so
// it is a question of how much code rather than of what the language allows,
// and gating a blocking read on a readiness report needs none of it: when the
// poller says there is something, the read that follows returns it without
// waiting.
//
// The result is an *idle* timeout -- no byte for this long -- rather than a
// deadline for the whole answer. That is the same guarantee `SO_RCVTIMEO`
// gives the reference client, and the only one a clock this coarse can
// honestly promise. Reads are gated and writes are not, which is also what the
// reference client does: a hang waiting for an answer is the failure that
// happens, and a hang writing a statement needs the server to stop reading
// mid-request.
const array = @import("std/array");
const bytes = @import("std/bytes");
const list = @import("std/list");
const net = @import("std/net");
const text = @import("std/str");
const message = @import("./message.ws");
const wire = @import("./wire.ws");

/// How large a single read off the socket may be.
///
/// The buffer is reused for the life of the connection, so this is a working
/// set rather than a limit: a body larger than this arrives over several reads
/// and is assembled in `inbuf`.
const CHUNK = 16384;

/// What a connection needs to know before it is made.
pub const Config = struct { token: str, timeout_ms: i64 };

/// The defaults: no token, and sixty seconds of silence before giving up --
/// which is what `quantydb connect` allows.
pub fn config() Config {
    return Config{ .token = "", .timeout_ms = 60000 };
}

/// A connection, after the handshake.
pub const Conn = struct {
    socket: net.Socket,
    /// Present exactly when a timeout is being enforced. Null is the blocking
    /// path, which needs no poller and pays for none.
    poll: ?net.Poller,
    timeout_ms: i64,
    /// Everything read off the socket and not yet consumed by a frame.
    inbuf: bytes.Buf,
    /// Reused for every read, so a connection allocates one of these and not
    /// one per message.
    scratch: []u8,
    /// Whether a statement is waiting to be drained.
    busy: bool,
    live: bool,
};

/// One frame, read whole.
pub const Frame = struct { kind: i64, body: []u8 };

// ---------------------------------------------------------------------------
// Opening
// ---------------------------------------------------------------------------

/// Connect to `host:port` with the default configuration.
pub fn connect(host: str, port: i64) !Conn {
    return try connect_with(host, port, config());
}

pub fn connect_with(host: str, port: i64, cfg: Config) !Conn {
    return try attach(try net.connect(host, port), cfg);
}

/// Shake hands over a socket the caller already has.
///
/// What makes the whole conversation testable without a server: a test can put
/// both ends of a loopback pair in one worker and drive this against canned
/// bytes.
pub fn attach(s: net.Socket, cfg: Config) !Conn {
    var poll: ?net.Poller = null;
    if (cfg.timeout_ms > 0) {
        const p = try net.poller();
        try net.watch(p, s, true, false);
        poll = p;
    }

    const c = Conn{
        .socket = s,
        .poll = poll,
        .timeout_ms = cfg.timeout_ms,
        .inbuf = bytes.buf(CHUNK),
        .scratch = bytes.new(CHUNK),
        .busy = false,
        .live = true,
    };

    try handshake(c);
    if (text.len(cfg.token) > 0) { try authenticate(c, cfg.token); }
    return c;
}

/// Say goodbye and let the socket go. Closing twice is harmless.
pub fn close(c: Conn) void {
    if (c.live) {
        c.live = false;
        // Best effort: a server that has already gone does not need telling,
        // and there is nothing useful to do about it here.
        if (goodbye(c)) { }
        net.close(c.socket);
        if (c.poll) |p| { net.close_poller(p); }
    }
    return;
}

fn goodbye(c: Conn) bool {
    send(c, message.close_frame()) catch return false;
    return true;
}

// ---------------------------------------------------------------------------
// The handshake
// ---------------------------------------------------------------------------

fn handshake(c: Conn) !void {
    try send(c, wire.hello(wire.VERSION));
    try fill(c, wire.SERVER_HELLO_LEN);

    const accepted = i64(c.inbuf.data[0]);
    const spoken = wire.le16(c.inbuf.data, 1);
    const reason = i64(c.inbuf.data[3]);
    bytes.drop_front(c.inbuf, wire.SERVER_HELLO_LEN);

    if (accepted != 1) {
        if (reason == wire.REFUSED_TOO_OLD) { return error.VersionTooOld; }
        if (reason == wire.REFUSED_TOO_NEW) { return error.VersionTooNew; }
        if (reason == wire.REFUSED_BAD_MAGIC) { return error.BadMagic; }
        return error.HandshakeRefused;
    }

    // "the version the server will speak ... is never higher than the version
    // the client asked for", so anything but our own is a version we do not
    // have the code for.
    if (spoken != wire.VERSION) { return error.UnsupportedVersion; }

    const f = try read_frame(c);
    if (f.kind != wire.T_READY) { return error.BadHandshake; }
    try message.read_empty(f.body);
    return;
}

/// Show a token, and find out whether it was accepted.
///
/// Per connection: a token accepted on one says nothing about any other, and
/// it is checked when `Auth` arrives, so revoking one shuts out new
/// connections rather than cutting off a conversation already under way.
fn authenticate(c: Conn, token: str) !void {
    try send(c, message.auth_frame(token));
    const f = try read_frame(c);

    if (f.kind == wire.T_READY) {
        try message.read_empty(f.body);
        return;
    }
    // The body is read and dropped: an `Error` here says `0x0004` and a
    // sentence, and `error.AuthFailed` already carries everything a caller can
    // act on. Reading it is what keeps the stream in step.
    if (f.kind == wire.T_ERROR) {
        const a = try message.read_failed(f.body);
        return error.AuthFailed;
    }
    return error.BadHandshake;
}

// ---------------------------------------------------------------------------
// Frames
// ---------------------------------------------------------------------------

/// The next frame from the server.
pub fn read_frame(c: Conn) !Frame {
    try fill(c, wire.HEADER_LEN);

    const kind = i64(c.inbuf.data[0]);
    const n = i64(bytes.le32(c.inbuf.data, 1));

    // Checked before the body is read rather than after, so a nonsense length
    // costs one comparison instead of an allocation. This bound is the whole
    // reason a decoder may allocate from a length field at all.
    if (n > wire.MAX_BODY) { return error.FrameTooLarge; }
    if (kind < wire.T_READY or kind > wire.T_ERROR) { return error.BadMessageType; }

    try fill(c, wire.HEADER_LEN + n);
    const body = bytes.slice(c.inbuf.data, wire.HEADER_LEN, wire.HEADER_LEN + n);
    bytes.drop_front(c.inbuf, wire.HEADER_LEN + n);
    return Frame{ .kind = kind, .body = body };
}

/// Write every byte of `frame`, however many calls that takes.
///
/// The socket is blocking, so this is `std/net`'s own loop and nothing more.
pub fn send(c: Conn, frame: []u8) !void {
    try net.write_all_bytes(c.socket, frame, 0, array.len(frame));
    return;
}

// ---------------------------------------------------------------------------
// Buffering
// ---------------------------------------------------------------------------

/// Read until `inbuf` holds at least `need` bytes.
fn fill(c: Conn, need: i64) !void {
    while (c.inbuf.used < need) {
        try pull(c);
    }
    return;
}

/// One read off the socket into the buffer.
fn pull(c: Conn) !void {
    try ready(c);
    const n = try net.read_into(c.socket, c.scratch, 0, array.len(c.scratch));
    // Zero is the far end finishing. A frame half read when that happens is a
    // truncated answer, not an empty one.
    if (n == 0) { return error.EndOfFile; }
    bytes.put_bytes(c.inbuf, c.scratch, 0, n);
    return;
}

/// Wait until there is something to read, or give up.
///
/// An empty result is the timeout: `net.wait` answers with whatever became
/// ready, and nothing becoming ready within `timeout_ms` is the only thing
/// this driver can tell a caller about a server that has gone quiet. With no
/// timeout configured there is no poller and this does nothing, which leaves
/// the read below to block exactly as it would have anyway.
fn ready(c: Conn) !void {
    if (c.poll) |p| {
        const events = try net.wait(p, c.timeout_ms);
        if (list.len(events) == 0) { return error.TimedOut; }
    }
    return;
}

// ---------------------------------------------------------------------------
// One request at a time
// ---------------------------------------------------------------------------

/// Claim the connection for a statement.
pub fn begin(c: Conn) !void {
    if (!c.live) { return error.Closed; }
    if (c.busy) { return error.RequestInFlight; }
    c.busy = true;
    return;
}

/// Give it back, once a terminal message has been read.
pub fn finished(c: Conn) void {
    c.busy = false;
    return;
}
