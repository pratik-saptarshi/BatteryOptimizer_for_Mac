#!/bin/bash
# Regression tests for battery.sh. Plain bash 3.2, no bats.
# Every test runs a rewritten, stubbed copy of battery.sh under a temp HOME
# (see tests/harness.sh). Nothing here touches the SMC, sudo, launchd or ~/.battery.
#
# Usage: BATTERY_TEST_TMPDIR=/some/scratch/dir tests/run.sh [name-filter]

# shellcheck source=tests/harness.sh
source "$(dirname "$0")/harness.sh"
trap bt_teardown_all EXIT
FILTER="${1:-}"

run_test() {
	local fn="$1"
	[[ -n "$FILTER" && "$fn" != *"$FILTER"* ]] && return 0
	echo "# $fn"
	"$fn"
}

# ---------------------------------------------------------------- R0: harness
test_r0_harness_refuses_foreign_home() {
	bt_setup smc_macos27.txt ioreg_macos27
	mkdir -p "$T/decoy"
	env -i HOME="$T/decoy" PATH=/usr/bin:/bin /bin/bash "$T/bin/battery" version >/dev/null 2>"$T/err"
	BT_RC=$?
	check "copy exits 99 when HOME is not the test home" [ "$BT_RC" -eq 99 ]
	check "copy did not create state in the foreign HOME" [ ! -e "$T/decoy/.battery" ]
	bt_teardown
}

test_r0_selfcheck_rejects_unrewritten_copy() {
	bt_setup smc_macos27.txt ioreg_macos27
	echo 'smc_binary=/usr/local/co.battery-optimizer/smc' >>"$T/bin/battery"
	(BT_ALL_ROOTS=() && bt_selfcheck) >/dev/null 2>&1
	BT_RC=$?
	check "self-check aborts on a copy naming the real smc" [ "$BT_RC" -eq 99 ]
	bt_teardown
}

test_r0_stubs_contain_side_effects() {
	bt_setup smc_macos27.txt ioreg_macos27
	local out
	out="$(env -i HOME="$T/home" PATH=/usr/bin:/bin /bin/bash -c "
		source '$T/stubs.sh'
		sudo /bin/echo should-not-run; echo \"sudo_rc=\$?\"
		sudo cp /nonexistent-bt-src '$T/x'; echo \"sudo_cp_rc=\$?\"
		kill -0 1; echo \"kill_rc=\$?\"
		pmset bt-noop-setter 1; echo \"pmset_rc=\$?\"
		type -t sudo
	" 2>&1)"
	BT_OUT="$out"
	check "sudo stub refuses commands outside the allowlist" grep -q '^sudo_rc=1$' <<<"$out"
	check "sudo stub refuses absolute paths outside the test root" grep -q '^sudo_cp_rc=1$' <<<"$out"
	check "kill stub refuses non-test pids" grep -q '^kill_rc=1$' <<<"$out"
	check "pmset stub refuses setters" grep -q '^pmset_rc=1$' <<<"$out"
	check "the command echoed by sudo never ran" bash -c "! grep -q '^should-not-run' <<<\"\$1\"" _ "$out"
	check "blocked calls are logged" grep -q 'BLOCKED' "$T/calls.log"
	bt_teardown
}

test_r0_smc_stub_serves_fixture_and_logs_writes() {
	bt_setup smc_macos27.txt ioreg_macos27
	check "absent key reads 'no data'" grep -q 'no data' <<<"$("$T/bin/smc" -k CHTE -r)"
	check "present key reads bytes" grep -q 'bytes 00' <<<"$("$T/bin/smc" -k CHIE -r)"
	"$T/bin/smc" -k CHIE -w 08
	check "write is logged" grep -qx 'CHIE -w 08' "$T/smc_writes.log"
	check "write is reflected in later reads" grep -q 'bytes 08' <<<"$("$T/bin/smc" -k CHIE -r)"
	bt_teardown
}

test_r0_version_runs_in_temp_home() {
	bt_setup smc_macos27.txt ioreg_macos27
	bt_run 20 version
	check "version runs under the harness" [ "$BT_RC" -eq 0 ]
	check "state dir created inside the temp HOME" [ -d "$T/home/.battery" ]
	check "no sudo/pmset/kill was blocked" bash -c "! grep -q BLOCKED '$T/calls.log'"
	bt_teardown
}

# ------------------------------------------------- R1: fail-loud capability gate
test_r1_maintain_refused_without_actuator_macos27() {
	bt_setup smc_macos27.txt ioreg_macos27
	bt_run 30 maintain 74
	check "maintain 74 exits non-zero on 27" [ "$BT_RC" -ne 0 ]
	check "maintain 74 says charge limiting is unsupported" grep -q 'charge limiting unsupported on this Mac/macOS: no CH0B/CH0C/CHTE/BCLM key' <<<"$BT_OUT"
	check "maintain 74 reports the native macOS limit" grep -q 'macOS charge limit active: 80% (manualChargeLimit)' <<<"$BT_OUT"
	check "maintain 74 wrote nothing to the SMC" [ ! -s "$T/smc_writes.log" ]
	check "maintain 74 created no LaunchAgent" [ ! -e "$T/home/Library/LaunchAgents/battery.plist" ]
	check "maintain 74 started no maintain_synchronous" bash -c "! /usr/bin/pgrep -f '$T/bin/battery maintain_synchronous' >/dev/null"

	bt_run 30 status
	check "status says NOT LIMITING" grep -q 'NOT LIMITING (no charge-control key)' <<<"$BT_OUT"
	check "status reports the native macOS limit" grep -q 'macOS charge limit active: 80% (manualChargeLimit)' <<<"$BT_OUT"
	bt_run 30 status_csv
	check "status_csv charging state is unknown, not enabled" [ "$(echo "$BT_OUT" | cut -d, -f3)" == "unknown" ]

	bt_run 15 maintain_synchronous 74
	check "maintain_synchronous 74 exits non-zero by itself (no loop)" test "$BT_RC" -ne 0 -a "$BT_TIMED_OUT" -eq 0
	bt_run 15 maintain_synchronous recover
	check "maintain_synchronous recover exits non-zero by itself" test "$BT_RC" -ne 0 -a "$BT_TIMED_OUT" -eq 0
	check "no SMC writes from maintain_synchronous" [ ! -s "$T/smc_writes.log" ]
	check "unsupported notification shown at most once" [ "$(grep -c 'osascript.*not supported' "$T/calls.log")" -le 1 ]
	bt_teardown
}

test_r1_maintain_still_works_macos26() {
	bt_setup smc_macos26.txt ioreg_macos27
	bt_run 30 maintain 74
	check "maintain 74 exits 0 on the 26 fixture" [ "$BT_RC" -eq 0 ]
	check "maintain 74 created the LaunchAgent" [ -f "$T/home/Library/LaunchAgents/battery.plist" ]
	check "loop disables charging via CHTE -w 01000000" bt_wait_for 20 "$T/smc_writes.log" "CHTE -w 01000000"
	bt_run 30 status
	check "status does not say NOT LIMITING on 26" bash -c "! grep -q 'NOT LIMITING' <<<\"\$1\"" _ "$BT_OUT"
	bt_teardown
}

test_r1_intel_bclm_path_unchanged() {
	bt_setup smc_intel.txt ioreg_legacy
	bt_start_bg maintain_synchronous 74
	check "intel loop disables charging via BCLM -w 0a" bt_wait_for 20 "$T/smc_writes.log" "BCLM -w 0a"
	kill "$BT_BG_PID" 2>/dev/null
	wait "$BT_BG_PID" 2>/dev/null
	bt_teardown
}

test_r1_unreadable_key_is_not_present() {
	bt_setup smc_macos27.txt ioreg_macos27
	# CHTE answers with an error instead of "no data": must not count as present.
	sed -i '' 's/^CHTE	.*/CHTE	Error: SMCReadKey() = e00002c1/' "$T/fx/smc.txt"
	bt_run 30 maintain_synchronous 74
	check "unknown CHTE: maintain_synchronous exits non-zero by itself" test "$BT_RC" -ne 0 -a "$BT_TIMED_OUT" -eq 0
	check "unknown CHTE: probe was retried and reported" grep -q 'still unreadable' <<<"$BT_OUT"
	check "unknown CHTE: no SMC writes" [ ! -s "$T/smc_writes.log" ]
	bt_teardown
}

# ------------------------------------------------------------ R2: ioreg parsing
# Expected values: 4751*100/6040 = 78.6, 12457 mV, 6040*100/6249 = 96.6, cycle 78.
# Temperature: 27 has no VirtualTemperature, so it comes from TB0T (30 -> 30.0);
# the legacy fixture has VirtualTemperature 3029 -> (3029+5)/100 = 30.3.
test_r2_metrics_macos27_plist() {
	bt_setup smc_macos27.txt ioreg_macos27
	bt_run 30 status
	check "27: status battery line" grep -q 'Battery at 78.6%, 12.457V, 30.0°C' <<<"$BT_OUT"
	check "27: status health line" grep -q 'Battery health 96.6%, Cycle 78' <<<"$BT_OUT"
	check "27: no bc/parse errors on stderr" bash -c "! grep -q -i 'error' <<<\"\$1\"" _ "$BT_ERR"
	bt_teardown
}

test_r2_metrics_legacy_layout() {
	bt_setup smc_macos27.txt ioreg_legacy
	bt_run 30 status
	check "legacy plist: status battery line" grep -q 'Battery at 78.6%, 12.457V, 30.3°C' <<<"$BT_OUT"
	check "legacy plist: status health line" grep -q 'Battery health 96.6%, Cycle 78' <<<"$BT_OUT"
	rm -f "$T/fx/ioreg.plist" # force the text/grep fallback
	bt_run 30 status
	check "legacy text: status battery line" grep -q 'Battery at 78.6%, 12.457V, 30.3°C' <<<"$BT_OUT"
	check "legacy text: status health line" grep -q 'Battery health 96.6%, Cycle 78' <<<"$BT_OUT"
	check "legacy text: no errors on stderr" bash -c "! grep -q -i 'error' <<<\"\$1\"" _ "$BT_ERR"
	bt_teardown
}

test_r2_empty_metric_fails_safe() {
	bt_setup smc_macos27.txt empty
	bt_run 30 discharge 50
	check "empty ioreg: discharge exits non-zero" test "$BT_RC" -ne 0 -a "$BT_TIMED_OUT" -eq 0
	check "empty ioreg: discharge does not claim completion" bash -c "! grep -q 'Discharging completed' <<<\"\$1\"" _ "$BT_OUT"
	check "empty ioreg: last SMC write restores the adapter (CHIE -w 00)" [ "$(tail -n 1 "$T/smc_writes.log")" == "CHIE -w 00" ]
	bt_run 30 charge 90
	check "empty ioreg: charge exits non-zero" test "$BT_RC" -ne 0 -a "$BT_TIMED_OUT" -eq 0
	check "empty ioreg: charge does not claim completion" bash -c "! grep -q 'Charging completed' <<<\"\$1\"" _ "$BT_OUT"
	bt_teardown

	bt_setup smc_macos26.txt empty
	bt_run 30 discharge 50
	check "empty ioreg (26): discharge exits non-zero" test "$BT_RC" -ne 0 -a "$BT_TIMED_OUT" -eq 0
	check "empty ioreg (26): adapter restored (CHIE -w 00 after CHIE -w 08)" bash -c "grep -E '^CHIE ' '$T/smc_writes.log' | tail -n 1 | grep -qx 'CHIE -w 00'"
	check "empty ioreg (26): charging re-enabled last (CHTE -w 00000000)" [ "$(tail -n 1 "$T/smc_writes.log")" == "CHTE -w 00000000" ]
	bt_teardown
}

# ------------------------------------------- R3: validate before killing anything
test_r3_maintain_bad_args_keep_running_loop() {
	local args
	for args in "abc" "0" "5" "101" "80 90" "80 80" "80 3" "80 abc"; do
		bt_setup smc_macos26.txt ioreg_macos27
		mkdir -p "$T/home/.battery"
		bt_dummy
		echo "$BT_DUMMY_PID active" >"$T/home/.battery/battery.pid"
		local cal_pid
		cal_pid="$(command sleep 300 >/dev/null 2>&1 & echo $!)"
		echo "$cal_pid" >>"$T/killable"
		echo "$cal_pid" >"$T/home/.battery/calibrate.pid"
		# shellcheck disable=SC2086
		bt_run 30 maintain $args
		check "maintain $args exits non-zero" [ "$BT_RC" -ne 0 ]
		check "maintain $args leaves the running loop alive" kill -0 "$BT_DUMMY_PID"
		check "maintain $args leaves calibration alive" kill -0 "$cal_pid"
		check "maintain $args wrote no config" bash -c "! grep -q maintain_percentage '$T/home/.battery/config_battery' 2>/dev/null"
		bt_teardown
	done
}

test_r3_maintain_valid_args_replace_loop() {
	bt_setup smc_macos26.txt ioreg_macos27
	mkdir -p "$T/home/.battery"
	bt_dummy
	echo "$BT_DUMMY_PID active" >"$T/home/.battery/battery.pid"
	bt_run 30 maintain 80 50
	check "maintain 80 50 exits 0" [ "$BT_RC" -eq 0 ]
	check "maintain 80 50 replaces the old loop" bash -c "! kill -0 $BT_DUMMY_PID 2>/dev/null"
	check "maintain 80 50 saved the setting" grep -q '^maintain_percentage = 80 50$' "$T/home/.battery/config_battery"
	bt_teardown
}

for t in $(declare -F | awk '{print $3}' | grep '^test_'); do
	run_test "$t"
done

echo
echo "passed: $BT_PASS  failed: $BT_FAIL"
if ((BT_FAIL > 0)); then
	printf '  failed: %s\n' "${BT_FAILED_NAMES[@]}"
	exit 1
fi
exit 0
