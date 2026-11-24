#!/usr/bin/env bash
# A networked git call of a CI step that never reached the remote is made again (PRD kaos#1911 AC-24).
# e2e run ml23, 2026-11-19 13:56 UTC: the pool's DNS failed for some seconds, `git clone` of two steps
# answered "Could not resolve host: github.com", and a pull request check and a build failed.
#
#   bash charts/custom/kubecore-ci-workflows/tests/git-retry/run.sh
#
# The wrapper is taken from the rendered chart and run in sh against a stub `git` that fails a given
# number of times. Needs helm. Exit status is the number of failed assertions.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
CHART="${HERE}/../.."
FAILED=0
PASSED=0
expect_eq() {
  if [ "$1" = "$2" ]; then PASSED=$((PASSED + 1)); echo "PASS: $3"
  else FAILED=$((FAILED + 1)); echo "FAIL: $3"; echo "  expected: $2"; echo "  actual:   $1"; fi
}
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
helm template t "$CHART" --set github.org=acme > "$T/rendered.yaml" || { echo "FAIL: helm template"; exit 1; }
# the first copy of the wrapper: from its `export GIT_HTTP_LOW_SPEED_LIMIT=` line to the line before `git_assert_no_token() {`
awk '/^ *export GIT_HTTP_LOW_SPEED_LIMIT=/ && !seen {seen=1; on=1} on && /^ *git_assert_no_token\(\) \{/ {exit} on {sub(/^ +/, ""); print}' \
  "$T/rendered.yaml" > "$T/wrapper.sh"
expect_eq "$(grep -c '^git() {' "$T/wrapper.sh")" "1" "the rendered chart holds the wrapper"

mkdir "$T/bin"
cat > "$T/bin/git" <<'STUB'
#!/bin/sh
# fails FAILS times with the line in ERR, then prints "ok <args>"
n=$(cat "$CALLS" 2>/dev/null || echo 0); n=$((n + 1)); echo "$n" > "$CALLS"
if [ "$n" -le "${FAILS:-0}" ]; then echo "${ERR}" >&2; exit "${RC:-128}"; fi
echo "ok $*"
STUB
chmod +x "$T/bin/git"

call() {  # call FAILS ERR ARGS... -> stdout of the wrapper; sets RC_GOT, CALLS_GOT, ERR_GOT
  fails=$1; err=$2; shift 2
  rm -f "$T/calls"
  OUT_GOT=$(PATH="$T/bin:$PATH" CALLS="$T/calls" FAILS="$fails" ERR="$err" GIT_RETRY_SLEEP=0 TOKEN="${TOKEN_FOR_CALL:-}" \
    sh -euc '. "$0"; git "$@"' "$T/wrapper.sh" "$@" 2>"$T/stderr")
  RC_GOT=$?
  CALLS_GOT=$(cat "$T/calls" 2>/dev/null || echo 0)
  ERR_GOT=$(cat "$T/stderr")
}
DNS="fatal: unable to access 'https://github.com/acme/app.git/': Could not resolve host: github.com (DNS server returned general failure)"

call 2 "$DNS" clone --depth=1 https://github.com/acme/app.git /tmp/x
expect_eq "$RC_GOT $CALLS_GOT" "0 3" "a clone that could not resolve the host twice succeeds on the third call"
expect_eq "$OUT_GOT" "ok clone --depth=1 https://github.com/acme/app.git /tmp/x" "its output is that of the call that succeeded, once"
expect_eq "$(printf '%s\n' "$ERR_GOT" | grep -c 'no connection to the remote (attempt')" "2" "each call that failed is said in the log"
expect_eq "$(printf '%s\n' "$ERR_GOT" | grep -c 'Could not resolve host')" "2" "git's own message is kept in the log"

call 99 "$DNS" fetch origin
expect_eq "$RC_GOT $CALLS_GOT" "128 6" "a remote that never answers fails with git's exit code after 6 calls"

call 99 "fatal: unable to access 'https://github.com/': Failed to connect to github.com port 443 after 130000 ms: Connection timed out" push
expect_eq "$CALLS_GOT" "6" "a refused or timed out connection is tried again"

call 99 "remote: Repository not found." clone https://github.com/acme/none.git /tmp/y
expect_eq "$RC_GOT $CALLS_GOT" "128 1" "a refusal by the remote is not tried again"

call 99 " ! [rejected]        dev -> dev (fetch first)" push
expect_eq "$RC_GOT $CALLS_GOT" "128 1" "a rejected push is not tried again"

call 99 "$DNS" commit -m x
expect_eq "$RC_GOT $CALLS_GOT" "128 1" "a call that is not networked is never tried again"

TOKEN_FOR_CALL="ghs_fake" call 1 "$DNS" ls-remote https://github.com/acme/app.git
expect_eq "$RC_GOT $CALLS_GOT" "0 2" "with a token the call is tried again the same way"
expect_eq "$(printf '%s' "$OUT_GOT$ERR_GOT" | grep -c ghs_fake)" "0" "the token is in no output"

# 2026-11-24 e2e run: curl's own 300 s bound ended in "Resolving timed out after 300101 milliseconds"
# and hera-enhance-commit failed on its one attempt. That wording, a reset, a gateway error and a
# call that outlived the per-call cap (exit 124) are the same kind of failure: made again.
RES="fatal: unable to access 'https://github.com/acme/gitops.git/': Resolving timed out after 300101 milliseconds"
call 2 "$RES" clone --depth=1 https://github.com/acme/gitops.git /tmp/x
expect_eq "$RC_GOT $CALLS_GOT" "0 3" "a clone whose name resolution timed out twice succeeds on the third call"
call 1 "fatal: unable to access 'https://github.com/acme/a.git/': Recv failure: Connection reset by peer" fetch origin
expect_eq "$RC_GOT $CALLS_GOT" "0 2" "a reset connection is tried again"
call 1 "fatal: unable to access 'https://github.com/acme/a.git/': The requested URL returned error: 503" fetch origin
expect_eq "$RC_GOT $CALLS_GOT" "0 2" "a 503 from the remote is tried again"
call 1 "error: RPC failed; HTTP 502 curl 22 The requested URL returned error: 502" push
expect_eq "$RC_GOT $CALLS_GOT" "0 2" "a failed push on a 502 is tried again"
RC=124 call 1 "" fetch origin
expect_eq "$RC_GOT $CALLS_GOT" "0 2" "a call ended by the per-call cap (124) is tried again"
RC=143 call 1 "Terminated" fetch origin
expect_eq "$RC_GOT $CALLS_GOT" "0 2" "a call ended by busybox timeout (143) is tried again"
call 99 "fatal: Authentication failed for 'https://github.com/acme/a.git/'" clone https://github.com/acme/a.git /tmp/y
expect_eq "$RC_GOT $CALLS_GOT" "128 1" "a refused login is not tried again"
call 99 "remote: Invalid username or token. Password authentication is not supported" fetch origin
expect_eq "$RC_GOT $CALLS_GOT" "128 1" "a refused token is not tried again"
call 99 "fatal: Remote branch nope not found in upstream origin" clone --branch nope https://github.com/acme/a.git /tmp/y
expect_eq "$RC_GOT $CALLS_GOT" "128 1" "a missing branch is not tried again"

# a clone that failed half way leaves nothing for the next call
rm -rf "$T/half"
cat > "$T/bin/git" <<'STUB'
#!/bin/sh
# clone: the first call leaves a half made target and fails, a later call fails if the target exists
n=$(cat "$CALLS" 2>/dev/null || echo 0); n=$((n + 1)); echo "$n" > "$CALLS"
for a; do t=$a; done
if [ "$n" -eq 1 ]; then mkdir -p "$t/.git"; echo "fatal: unable to access 'x': Resolving timed out after 300101 milliseconds" >&2; exit 128; fi
if [ -e "$t" ]; then echo "fatal: destination path exists" >&2; exit 128; fi
echo "ok"
STUB
call 0 "" clone https://github.com/acme/a.git "$T/half"
expect_eq "$RC_GOT $CALLS_GOT" "0 2" "a clone is made again into a clean target"

# the git defaults that end a stalled transfer
OUT_GOT=$(cd "$T" && sh -c '. "$0"; printf "%s %s" "$GIT_HTTP_LOW_SPEED_LIMIT" "$GIT_HTTP_LOW_SPEED_TIME"' "$T/wrapper.sh")
expect_eq "$OUT_GOT" "1000 60" "a transfer under 1 kB/s for 60 s is ended by git"

echo "passed: ${PASSED}, failed: ${FAILED}"
exit "$FAILED"
