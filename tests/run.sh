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

# -------------------------------------------------------------- R4: validators
# The validators are pure (regex + arithmetic), so they are extracted from
# battery.sh and evaluated on their own.
bt_validators() {
	sed -n '/^function valid_percentage()/,/^function format00()/p' "$BT_REPO/battery.sh" | sed '$d'
	sed -n '/^function valid_number_in_range()/,/^}/p' "$BT_REPO/battery.sh"
}

test_r4_validators() {
	local defs out T_ERR
	bt_setup smc_macos27.txt ioreg_macos27
	T_ERR="$T/validators.err"
	defs="$(bt_validators)"
	out="$(/bin/bash -c "$defs"'
		t() { local f=$1; shift; local v; for v in "$@"; do if $f "$v"; then echo "$f $v accept"; else echo "$f $v reject"; fi; done; }
		t valid_percentage 08 080 18446744073709551624 101 -1 "" "1 2" abc 0x10 0 8 10 100
		t valid_day 0 29 08 1 28
		t valid_hour 24 08 0 23
		t valid_minute 60 09 0 59
		t valid_weekday 7 06 0 6
		t valid_week_period 0 13 1 12
		t valid_month_period 0 4 1 3
	' 2>"$T_ERR")"
	BT_OUT="$out"
	local exp
	for exp in "valid_percentage 08 reject" "valid_percentage 080 reject" "valid_percentage 18446744073709551624 reject" \
		"valid_percentage 101 reject" "valid_percentage -1 reject" "valid_percentage  reject" "valid_percentage abc reject" \
		"valid_percentage 0x10 reject" "valid_percentage 0 accept" "valid_percentage 8 accept" "valid_percentage 10 accept" \
		"valid_percentage 100 accept" "valid_day 0 reject" "valid_day 29 reject" "valid_day 08 reject" "valid_day 1 accept" \
		"valid_day 28 accept" "valid_hour 24 reject" "valid_hour 08 reject" "valid_hour 0 accept" "valid_hour 23 accept" \
		"valid_minute 60 reject" "valid_minute 09 reject" "valid_minute 0 accept" "valid_minute 59 accept" \
		"valid_weekday 7 reject" "valid_weekday 06 reject" "valid_weekday 0 accept" "valid_weekday 6 accept" \
		"valid_week_period 0 reject" "valid_week_period 13 reject" "valid_week_period 1 accept" "valid_week_period 12 accept" \
		"valid_month_period 0 reject" "valid_month_period 4 reject" "valid_month_period 1 accept" "valid_month_period 3 accept"; do
		check "$exp" grep -qxF -- "$exp" <<<"$out"
	done
	BT_ERR="$(cat "$T_ERR")"
	check "validators print nothing on stderr (no 'value too great for base')" [ ! -s "$T_ERR" ]
	bt_teardown
}

test_r4_charge_rejects_octal() {
	bt_setup smc_macos27.txt ioreg_macos27
	local v
	for v in 08 080 18446744073709551624; do
		bt_run 30 charge "$v"
		check "charge $v is rejected" test "$BT_RC" -ne 0 -a "$BT_TIMED_OUT" -eq 0
		check "charge $v: says 'not a valid setting'" grep -q 'not a valid setting' <<<"$BT_OUT"
		check "charge $v: no 'value too great for base'" bash -c "! grep -q 'value too great' <<<\"\$1\"" _ "$BT_ERR"
	done
	bt_teardown
}

test_r4_stored_zero_padded_schedule_day_still_works() {
	bt_setup smc_macos27.txt ioreg_macos27
	mkdir -p "$T/home/.battery"
	echo "calibrate_schedule = Schedule calibration on day 08 at 9:00" >"$T/home/.battery/config_battery"
	bt_run 30 schedule enable
	local next
	next="$(sed -n 's/^calibrate_next = //p' "$T/home/.battery/config_battery")"
	check "stored 'day 08' still yields a next calibration time" grep -qE '^[0-9]{9,}$' <<<"$next"
	check "stored 'day 08': no arithmetic errors" bash -c "! grep -q 'value too great' <<<\"\$1\"" _ "$BT_ERR"
	bt_teardown
}

test_r4_schedule_rejects_bad_day_explicitly() {
	bt_setup smc_macos27.txt ioreg_macos27
	bt_run 30 schedule day 08
	check "schedule day 08 is an explicit error" test "$BT_RC" -ne 0
	check "schedule day 08: no 'value too great for base'" bash -c "! grep -q 'value too great' <<<\"\$1\"" _ "$BT_ERR"
	bt_teardown
}

# ----------------------------------------------------------------- R5: log trim
test_r5_log_trim_keeps_last_100_lines() {
	bt_setup smc_macos27.txt ioreg_macos27
	mkdir -p "$T/home/.battery"
	awk 'BEGIN{for(i=0;i<120000;i++) printf "line %06d padding padding padding padding\n", i}' >"$T/home/.battery/battery.log"
	check "fixture log is over 5 MB" [ "$(stat -f%z "$T/home/.battery/battery.log")" -gt 5000000 ]
	bt_run 30 version
	check "trimmed log has exactly 100 lines" [ "$(wc -l <"$T/home/.battery/battery.log" | tr -d ' ')" -eq 100 ]
	check "trimmed log keeps the newest line" [ "$(tail -n 1 "$T/home/.battery/battery.log")" == "line 119999 padding padding padding padding" ]
	check "trimmed log starts at line 119900" [ "$(head -n 1 "$T/home/.battery/battery.log")" == "line 119900 padding padding padding padding" ]
	check "no temp file left behind" [ ! -e "$T/home/.battery/battery.log.tmp" ]
	bt_teardown
}

# ------------------------------------------------------------ R7: curl hardening
test_r7_changelog_fetch_times_out() {
	bt_setup smc_macos27.txt ioreg_macos27
	# The curl stub never answers; with --max-time it gives up (compressed to 1 s),
	# without it each call blocks 20 s and this 12 s budget is exceeded.
	BT_CURL_MODE=hang bt_run 12 changelog
	check "changelog returns within the timeout when the server never answers" [ "$BT_TIMED_OUT" -eq 0 ]
	check "every curl call passed -q first" bash -c "! grep '^curl ' '$T/calls.log' | grep -v '^curl -q ' | grep -q ."
	bt_teardown
}

# ---------------------------------------------------------- R8: visudo exit code
# Runs only the rewritten copy: sudoers.d is $T/sudoers.d and visudo is a stub.
test_r8_visudo_validation_failure_exits_nonzero() {
	bt_setup smc_macos27.txt ioreg_macos27
	BT_VISUDO_RC=1 bt_run 30 visudo
	check "visudo action exits non-zero when visudo -c fails" [ "$BT_RC" -ne 0 ]
	check "invalid sudoers file is not installed" [ ! -e "$T/sudoers.d/battery" ]
	check "nothing escaped the sandbox" bash -c "! grep -q BLOCKED '$T/calls.log'"
	BT_VISUDO_RC=0 bt_run 30 visudo
	check "visudo action still exits 0 when validation passes" [ "$BT_RC" -eq 0 ]
	check "valid sudoers file is installed (in the test root)" [ -f "$T/sudoers.d/battery" ]
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
