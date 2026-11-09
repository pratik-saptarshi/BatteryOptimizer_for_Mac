#!/bin/bash
# Static checks: bash -n on every script, and shellcheck at error severity gated on
# the baseline recorded for v2.0.31 (8 error blocks across battery.sh, setup.sh,
# update.sh). Set SHELLCHECK to the shellcheck binary if it is not on PATH.

cd "$(dirname "$0")/.." || exit 1
SHELLCHECK="${SHELLCHECK:-shellcheck}"
SC_ERROR_BASELINE=8
fail=0

for f in battery.sh setup.sh update.sh tests/*.sh; do
	if bash -n "$f"; then echo "ok   - bash -n $f"; else echo "FAIL - bash -n $f"; fail=1; fi
done

if ! command -v "$SHELLCHECK" >/dev/null 2>&1; then
	echo "FAIL - shellcheck not found (set SHELLCHECK=/path/to/shellcheck)"
	exit 1
fi

n_err="$("$SHELLCHECK" -S error battery.sh setup.sh update.sh | grep -c '^In ')"
if ((n_err <= SC_ERROR_BASELINE)); then
	echo "ok   - shellcheck -S error: $n_err blocks (baseline $SC_ERROR_BASELINE)"
else
	echo "FAIL - shellcheck -S error: $n_err blocks, above baseline $SC_ERROR_BASELINE"
	"$SHELLCHECK" -S error -f gcc battery.sh setup.sh update.sh
	fail=1
fi

# R6: calibrate log used $n_second (unset) instead of $n_seconds
if "$SHELLCHECK" -f gcc -i SC2154 battery.sh | grep -q 'n_second'; then
	echo "FAIL - SC2154: n_second referenced but not assigned"
	fail=1
else
	echo "ok   - SC2154: no unassigned n_second"
fi

if "$SHELLCHECK" -S error -x tests/*.sh >/dev/null; then
	echo "ok   - shellcheck -S error tests/*.sh"
else
	echo "FAIL - shellcheck -S error tests/*.sh"
	"$SHELLCHECK" -S error -x -f gcc tests/*.sh
	fail=1
fi

exit $fail
