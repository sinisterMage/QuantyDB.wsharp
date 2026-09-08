#!/bin/sh
# Run every case in this directory and compare it against what it declares.
#
# The same contract the W# compiler's own suite uses, and sharpie's after it: a
# case is a `.ws` program whose header comment holds one `// expect:` line per
# line it should print, in order. There is no Rust here to hang a harness off,
# so this is the harness.
#
# `WSHARP` names the compiler; by default whichever one is on the path, which
# on a machine with sharpie installed is the toolchain sharpie chose.
#
# Every case here runs without a network and without a server. The codec is
# written against `[]u8`, and the one case that needs a socket makes a loopback
# pair inside itself -- see session.ws. `live.sh` beside this is the other half:
# the same driver against a real `quantydb serve`.
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$root"

WSHARP=${WSHARP:-wsharp}
if ! [ -x "$WSHARP" ] && ! command -v "$WSHARP" >/dev/null 2>&1; then
    echo "no compiler at \`$WSHARP\`; set WSHARP to one" >&2
    exit 2
fi

pass=0
fail=0
failed=""

for case in tests/*.ws; do
    [ -e "$case" ] || continue
    name=${case#tests/}

    # Every `// expect:` line, in the order written, with the marker removed.
    want=$(sed -n 's|^// expect: \{0,1\}||p' "$case")

    # `// env: NAME=value`, one per line, set for this case only.
    env_args=""
    while IFS= read -r assignment; do
        [ -n "$assignment" ] || continue
        env_args="$env_args $assignment"
    done <<EOF
$(sed -n 's|^// env: \{0,1\}||p' "$case")
EOF

    # Unquoted on purpose: `env_args` is a list of assignments, not one word.
    if got=$(env $env_args "$WSHARP" run "$case" 2>&1); then
        status=0
    else
        status=$?
    fi

    if [ "$status" -ne 0 ]; then
        fail=$((fail + 1))
        failed="$failed $name"
        printf '%s ... FAILED (exit %s)\n' "$name" "$status"
        printf '%s\n' "$got" | sed 's/^/    /'
        continue
    fi

    if [ "$got" = "$want" ]; then
        pass=$((pass + 1))
        printf '%s ... ok\n' "$name"
    else
        fail=$((fail + 1))
        failed="$failed $name"
        printf '%s ... FAILED\n' "$name"
        # Both sides, because which line drifted is the whole question.
        printf '%s\n' "$want" > "${TMPDIR:-/tmp}/quantydb-want.$$"
        printf '%s\n' "$got" > "${TMPDIR:-/tmp}/quantydb-got.$$"
        diff -u "${TMPDIR:-/tmp}/quantydb-want.$$" "${TMPDIR:-/tmp}/quantydb-got.$$" \
            | sed 's/^/    /' || true
        rm -f "${TMPDIR:-/tmp}/quantydb-want.$$" "${TMPDIR:-/tmp}/quantydb-got.$$"
    fi
done

printf '\n%s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ] || { printf 'failed:%s\n' "$failed"; exit 1; }
