#!/bin/bash
# Observational probe: prints how the current battery.sh behaves on the fixtures,
# without asserting anything. Used to record tests/BASELINE.txt on the unmodified
# code (develop @ 00dcc60). All execution goes through tests/harness.sh.
#
# Usage: BATTERY_TEST_TMPDIR=/some/scratch/dir tests/baseline.sh

# shellcheck source=tests/harness.sh
source "$(dirname "$0")/harness.sh"
trap bt_teardown_all EXIT

say() { printf '%s\n' "$*"; }

say "== B1 status on macOS 27 fixture (no charge-inhibit key)"
bt_setup smc_macos27.txt ioreg_macos27
bt_run 30 status
say "rc=$BT_RC"
say "$BT_OUT"
bt_run 30 status_csv
say "status_csv: $BT_OUT"
say "smc writes: $(wc -l <"$T/smc_writes.log" | tr -d ' ')"

say ""
say "== B2 maintain_synchronous 74 on macOS 27 fixture (watch for 3 s)"
BT_SLEEP_MAX=0.2 bt_start_bg maintain_synchronous 74
command sleep 3
kill "$BT_BG_PID" 2>/dev/null
wait "$BT_BG_PID" 2>/dev/null
say "log lines claiming to stop charging: $(grep -c 'Stop charge above' "$T/out")"
say "smc writes to CH0B/CH0C/CHTE/BCLM: $(grep -c -E '^(CH0B|CH0C|CHTE|BCLM) ' "$T/smc_writes.log")"
say "first output lines:"
head -n 6 "$T/out"
bt_teardown

say ""
say "== B3 ioreg getters on macOS 27 fixture (status line)"
bt_setup smc_macos27.txt ioreg_macos27
bt_run 30 status
say "$(echo "$BT_OUT" | grep -E 'Battery at|health')"
say "stderr (first 3): $(echo "$BT_ERR" | head -n 3)"
bt_teardown

say ""
say "== B4 discharge 50 on macOS 27 fixture"
bt_setup smc_macos27.txt ioreg_macos27
bt_run 30 discharge 50
say "rc=$BT_RC"
say "$(echo "$BT_OUT" | grep -E 'Discharg')"
say "smc writes: $(tr '\n' ';' <"$T/smc_writes.log")"
bt_teardown

say ""
say "== B5 log trim of a >5 MB log"
bt_setup smc_macos27.txt ioreg_macos27
mkdir -p "$T/home/.battery"
awk 'BEGIN{for(i=0;i<120000;i++) printf "line %06d padding padding padding padding\n", i}' >"$T/home/.battery/battery.log"
say "before: $(wc -l <"$T/home/.battery/battery.log" | tr -d ' ') lines, $(stat -f%z "$T/home/.battery/battery.log") bytes"
bt_run 30 version
say "after:  $(wc -l <"$T/home/.battery/battery.log" | tr -d ' ') lines"
bt_teardown

say ""
say "== B6 maintain with bad args kills the running loop first (26 fixture)"
for args in "abc" "0" "80 90"; do
	bt_setup smc_macos26.txt ioreg_macos27
	mkdir -p "$T/home/.battery"
	bt_dummy
	echo "$BT_DUMMY_PID active" >"$T/home/.battery/battery.pid"
	# shellcheck disable=SC2086
	bt_run 30 maintain $args
	if kill -0 "$BT_DUMMY_PID" 2>/dev/null; then alive=yes; else alive=no; fi
	say "maintain $args -> rc=$BT_RC, dummy loop alive=$alive"
	bt_teardown
done

say ""
say "== B7 validators"
bt_setup smc_macos27.txt ioreg_macos27
for v in 08 080 18446744073709551624 101 8 10 100; do
	bt_run 30 charge "$v"
	say "charge $v -> rc=$BT_RC $(echo "$BT_OUT" | grep -o 'not a valid setting' | head -n1) stderr: $(echo "$BT_ERR" | grep -o 'value too great[^)]*' | head -n1)"
done
bt_teardown

say ""
say "== B8 visudo with a failing visudo -c"
bt_setup smc_macos27.txt ioreg_macos27
BT_VISUDO_RC=1 bt_run 30 visudo
say "rc=$BT_RC"
bt_teardown

say ""
say "== B9 SIGHUP during discharge (26 smc fixture, legacy ioreg so the loop actually runs)"
bt_setup smc_macos26.txt ioreg_legacy
BT_SLEEP_MAX=0.3 bt_start_bg discharge 50
if bt_wait_for 20 "$T/smc_writes.log" "CHIE -w 08"; then
	command sleep 0.5
	kill -HUP "$BT_BG_PID"
	wait "$BT_BG_PID"
	say "rc=$?"
else
	say "discharge never enabled the CHIE adapter cut"
fi
command sleep 1.5
say "smc writes: $(tr '\n' ';' <"$T/smc_writes.log")"
say "last adapter write: $(grep -E '^(CHIE|CH0I|CH0J) ' "$T/smc_writes.log" | tail -n1)"
bt_teardown

say ""
say "== B10 shellcheck SC2154 (n_second)"
if [[ -n "${SHELLCHECK:-}" ]]; then
	"$SHELLCHECK" -f gcc -i SC2154 "$BT_REPO/battery.sh"
else
	say "(SHELLCHECK not set)"
fi
