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
