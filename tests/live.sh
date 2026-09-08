#!/bin/sh
# The driver against a real `quantydb serve`.
#
# `tests/run.sh` beside this checks the codec against bytes transcribed from
# `docs/PROTOCOL.md`. That catches a driver that disagrees with the document
# and cannot catch a document both halves have misread, so this is the other
# side: a server built from source, a token minted by its own CLI, and every
# statement answered by the thing the driver exists to talk to.
#
#     ./tests/live.sh                       # clone and build the server
#     QUANTYDB=/path/to/quantydb ./tests/live.sh
#
# Skips rather than fails when there is nothing to build with, so it can sit in
# a pipeline that does not always have a Rust toolchain.
#
# `quantydb serve` is Linux only -- it needs epoll -- so this is too.
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$root"

WSHARP=${WSHARP:-wsharp}
PORT=${PORT:-7979}
work=${TMPDIR:-/tmp}/quantydb-live.$$

if ! [ -x "$WSHARP" ] && ! command -v "$WSHARP" >/dev/null 2>&1; then
    echo "no compiler at \`$WSHARP\`; set WSHARP to one" >&2
    exit 2
fi

# Find a server, or build one. `QUANTYDB` short-circuits both.
if [ "${QUANTYDB:-}" = "" ]; then
    if command -v quantydb >/dev/null 2>&1; then
        QUANTYDB=$(command -v quantydb)
    else
        if ! command -v cargo >/dev/null 2>&1; then
            echo "no quantydb and no cargo to build one; skipping" >&2
            exit 0
        fi
        # Outside the package, so a clone of somebody else's repository never
        # ends up inside this one.
        build=${QUANTYDB_SRC:-${TMPDIR:-/tmp}/quantydb-src}
        if ! [ -d "$build/.git" ]; then
            echo "cloning QuantyDatabase into $build"
            git clone --depth 1 https://github.com/QuantyRoot/QuantyDatabase.git "$build" \
                || { echo "could not clone; skipping" >&2; exit 0; }
        fi
        echo "building the server (this takes a few minutes the first time)"
        (cd "$build" && cargo build --release) \
            || { echo "could not build the server; skipping" >&2; exit 0; }
        QUANTYDB="$build/target/release/quantydb"
    fi
fi

mkdir -p "$work"
server=""
cleanup() {
    [ -n "$server" ] && kill "$server" 2>/dev/null || true
    rm -rf "$work"
}
trap cleanup EXIT INT TERM

"$QUANTYDB" create "$work/live.qdb" >/dev/null

# `token` prints the secret and, separately, the line that accepts it. The
# secret goes on the wire as those characters; the line goes in the file.
minted=$("$QUANTYDB" token livetest)
token=$(printf '%s\n' "$minted" | awk '/^token/ { print $2 }')
printf '%s\n' "$minted" | awk '/^line/ { print $2, $3 }' > "$work/live.tokens"
chmod 600 "$work/live.tokens"

"$QUANTYDB" serve "$work/live.qdb" --listen "127.0.0.1:$PORT" --tokens "$work/live.tokens" \
    > "$work/server.log" 2>&1 &
server=$!

# Wait for the port rather than guessing at a sleep.
ready=0
i=0
while [ "$i" -lt 50 ]; do
    if grep -q "^listening on" "$work/server.log" 2>/dev/null; then
        ready=1
        break
    fi
    if ! kill -0 "$server" 2>/dev/null; then
        echo "the server exited before it listened:" >&2
        cat "$work/server.log" >&2
        exit 1
    fi
    i=$((i + 1))
    sleep 0.2
done
if [ "$ready" -ne 1 ]; then
    echo "the server did not start listening:" >&2
    cat "$work/server.log" >&2
    exit 1
fi

if ! "$WSHARP" run tests/live/main.ws -- 127.0.0.1 "$PORT" "$token" > "$work/got" 2>&1; then
    echo "the driver exited non-zero:" >&2
    cat "$work/got" >&2
    exit 1
fi

# What a correct client sees. Written out rather than recorded, so that a
# change in the driver's behaviour has to be agreed to here.
cat > "$work/want" <<'EOF'
table: ok
put: put 2
set: set 1
columns: id,ratio,label,raw,flag,spare
row: 1|3.25|hi|x"beef"|true|null
row: 2|0.5|there|x""|false|null
the result ended cleanly: true
one row came back: true
int, float, text, bytes, bool, null: true
and their contents: true
show tables is lines: true
show tables: things
log is lines: true
sql: there
a bad statement is a failure answer: true
with a code, not just a sentence: true
still usable: things
many: put 3
streamed: 5
del: del 3
drop: ok
unauthenticated: true
a wrong token is refused: true
EOF

if diff -u "$work/want" "$work/got"; then
    echo "live: ok"
else
    echo "live: FAILED" >&2
    exit 1
fi
