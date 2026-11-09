#!/bin/bash
# shellcheck disable=SC2034
#
# Test harness for battery.sh. Sourced by tests/run.sh and tests/baseline.sh.
#
# Safety model (read before changing anything here):
#   * battery.sh is NEVER executed in place. Each test makes a temp root $T, copies
#     battery.sh to $T/bin/battery and rewrites every system path in the copy
#     (/usr/local/co.battery-optimizer, /usr/local/bin, /private/etc/sudoers.d,
#     /etc/paths.d, /opt/homebrew) to point inside $T.
#   * Shell-function stubs for sudo, smc side effects, osascript, launchctl, curl,
#     pmset, ioreg, pgrep, pkill, kill, caffeinate, sleep, defaults, open, visudo,
#     chown and chmod are injected into the copy right after its PATH block, so they
#     shadow the real commands for the copy and for every nested $battery_binary call.
#     PATH shims are not used (the script prepends /opt/homebrew/bin to PATH).
#   * smc is a stub script ($T/bin/smc) that serves a fixture and logs every -w to
#     $T/smc_writes.log. It never talks to the SMC.
#   * HOME is $T/home. The copy aborts (exit 99) if HOME is anything else.
#   * The harness aborts before running anything if the rewritten copy still names
#     a real install/system path, or if `sudo` does not resolve to a function.

BT_REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BT_FIXTURES="$BT_REPO/tests/fixtures"
BT_BASE="${BATTERY_TEST_TMPDIR:-${TMPDIR:-/tmp}}"
BT_REAL_HOME="$(dscl . -read "/Users/$(id -un)" NFSHomeDirectory 2>/dev/null | awk '{print $2}')"
[[ -z $BT_REAL_HOME ]] && BT_REAL_HOME="$HOME"
BT_ALL_ROOTS=()

bt_abort() {
	echo "HARNESS ABORT: $*" >&2
	bt_teardown_all
	exit 99
}

# The stub block injected into the copy. @BT_ROOT@ is replaced with the temp root.
bt_stub_block() {
	cat <<'STUBS'
## ---- BEGIN TEST HARNESS STUBS (injected by tests/harness.sh, never shipped) ----
BT_ROOT='@BT_ROOT@'
if [[ "$HOME" != "$BT_ROOT/home" ]]; then echo "HARNESS ABORT: HOME=$HOME is not the test home" >&2; exit 99; fi
bt_log() { echo "$*" >>"$BT_ROOT/calls.log"; }
bt_inside() { case "$1" in "$BT_ROOT"/*) return 0 ;; esac; return 1; }
sudo() {
	bt_log "sudo $*"
	if [[ "$1" == "-u" ]]; then shift 2; fi
	local a
	for a in "$@"; do
		case "$a" in /*) bt_inside "$a" || { bt_log "BLOCKED sudo (path outside test root): $*"; return 1; } ;; esac
	done
	case "$1" in
		"$BT_ROOT"/bin/smc | "$BT_ROOT"/bin/battery | rm | cp | mkdir | cmp | visudo | chown | chmod | launchctl | osascript) "$@" ;;
		*) bt_log "BLOCKED sudo (command not allowed): $*"; return 1 ;;
	esac
}
chown() { bt_log "chown $*"; return 0; }
chmod() { bt_log "chmod $*"; return 0; }
visudo() { bt_log "visudo $*"; return "${BT_VISUDO_RC:-0}"; }
osascript() {
	bt_log "osascript $*"
	case "$*" in *"button returned"*) echo "${BT_OSA_ANSWER:-No}" ;; esac
	return 0
}
launchctl() { bt_log "launchctl $*"; return 0; }
defaults() { bt_log "defaults $*"; echo "en_US"; }
open() { bt_log "BLOCKED open $*"; return 0; }
pgrep() { bt_log "pgrep $*"; return 1; }
pkill() { bt_log "BLOCKED pkill $*"; return 0; }
kill() {
	bt_log "kill $*"
	local a n=0
	for a in "$@"; do
		if [[ "$a" =~ ^[0-9]+$ ]]; then
			n=$((n + 1))
			if ! grep -qx "$a" "$BT_ROOT/killable" 2>/dev/null && ! ps -o command= -p "$a" 2>/dev/null | grep -qF "$BT_ROOT/"; then
				bt_log "BLOCKED kill $* (pid $a is not a test process)"
				return 1
			fi
		fi
	done
	[[ $n -gt 0 ]] || return 1
	builtin kill "$@"
}
caffeinate() { bt_log "caffeinate $*"; while [[ "$1" == -* ]]; do shift; done; "$@"; }
sleep() {
	local d="${1:-0}" max="${BT_SLEEP_MAX:-0.05}"
	if awk "BEGIN{exit !($d > $max)}" 2>/dev/null; then d="$max"; fi
	command sleep "$d"
}
pmset() {
	bt_log "pmset $*"
	case "$*" in
		"-g batt") cat "$BT_ROOT/fx/pmset_batt" 2>/dev/null ;;
		"-g battlimit") cat "$BT_ROOT/fx/pmset_battlimit" 2>/dev/null ;;
		*) bt_log "BLOCKED pmset $*"; return 1 ;;
	esac
}
ioreg() {
	bt_log "ioreg $*"
	case "$*" in
		*AppleClamshellState*) echo '      "AppleClamshellState" = No' ;;
		-a*) cat "$BT_ROOT/fx/ioreg.plist" 2>/dev/null ;;
		*) cat "$BT_ROOT/fx/ioreg.txt" 2>/dev/null ;;
	esac
}
curl() {
	bt_log "curl $*"
	local a prev="" mt=""
	for a in "$@"; do
		if [[ "$prev" == "--max-time" || "$prev" == "-m" ]]; then mt="$a"; fi
		prev="$a"
	done
	case "${BT_CURL_MODE:-fail}" in
		hang)
			# Emulates a server that never answers. With --max-time curl gives up (time
			# compressed to 1s here); without it the call blocks far past any test timeout.
			# argv[0] carries the test root so teardown can find and stop the sleeper.
			if [[ -n "$mt" ]]; then (exec -a "$BT_ROOT/curl-hang" sleep 1); else (exec -a "$BT_ROOT/curl-hang" sleep 20); fi
			return 28 ;;
		*) return 22 ;;
	esac
}
if [[ "$(type -t sudo)" != "function" ]]; then echo "HARNESS ABORT: sudo is not stubbed" >&2; exit 99; fi
## ---- END TEST HARNESS STUBS ----
STUBS
}

bt_smc_stub() {
	cat <<'SMC'
#!/bin/bash
# smc test stub: serves $BT_ROOT/fx/smc.txt, records writes. Never touches hardware.
BT_ROOT='@BT_ROOT@'
key="" mode="" val=""
while [[ $# -gt 0 ]]; do
	case "$1" in
		-k) key="$2"; shift 2 ;;
		-r) mode=r; shift ;;
		-w) mode=w; val="$2"; shift 2 ;;
		*) echo "smc stub: unsupported argument $1" >&2; exit 2 ;;
	esac
done
state="$BT_ROOT/smc_state/$key"
if [[ -f "$state" ]]; then
	line="$(cat "$state")"
else
	line="$(awk -F'\t' -v k="$key" '$1==k {print $2; exit}' "$BT_ROOT/fx/smc.txt")"
	[[ -z "$line" ]] && line="  $key  [    ]  no data"
fi
if [[ "$mode" == "w" ]]; then
	echo "$key -w $val" >>"$BT_ROOT/smc_writes.log"
	if [[ "$line" == *"bytes"* ]]; then
		type="$(echo "$line" | sed -E 's/^[^[]*(\[[^]]*\]).*/\1/')"
		bytes="$(echo "$val" | sed -E 's/(..)/\1 /g; s/ $//')"
		echo "  $key  $type  (bytes $bytes)" >"$state"
	fi
	exit 0
fi
echo "$line"
SMC
}

# bt_setup <smc fixture> <ioreg fixture base, e.g. ioreg_macos27 or "empty">
# Creates a fresh temp root in $T with a rewritten, stubbed copy of battery.sh.
bt_setup() {
	local smc_fx="$1" ioreg_fx="$2" src="${BT_SCRIPT:-$BT_REPO/battery.sh}"
	[[ -d "$BT_BASE" ]] || bt_abort "temp base $BT_BASE does not exist"
	T="$(mktemp -d "$BT_BASE/bt.XXXXXX")" || bt_abort "mktemp failed"
	BT_ALL_ROOTS+=("$T")
	case "$T" in *" "*) bt_abort "temp root contains a space: $T" ;; esac
	case "$T/home" in "$BT_REAL_HOME" | "$BT_REAL_HOME"/.battery*) bt_abort "test HOME would be the real home" ;; esac
	[[ "$T/home" != "$BT_REAL_HOME" ]] || bt_abort "test HOME equals real HOME"
	mkdir -p "$T/home" "$T/bin" "$T/usrlocalbin" "$T/sudoers.d" "$T/paths.d" "$T/tmp" "$T/smc_state" "$T/fx"
	: >"$T/smc_writes.log"
	: >"$T/calls.log"
	: >"$T/killable"

	cp "$BT_FIXTURES/$smc_fx" "$T/fx/smc.txt"
	if [[ "$ioreg_fx" != "empty" ]]; then
		[[ -f "$BT_FIXTURES/$ioreg_fx.plist" ]] && cp "$BT_FIXTURES/$ioreg_fx.plist" "$T/fx/ioreg.plist"
		[[ -f "$BT_FIXTURES/$ioreg_fx.txt" ]] && cp "$BT_FIXTURES/$ioreg_fx.txt" "$T/fx/ioreg.txt"
	fi
	cp "$BT_FIXTURES/pmset_batt_ac.txt" "$T/fx/pmset_batt"
	cp "$BT_FIXTURES/pmset_battlimit_macos27.txt" "$T/fx/pmset_battlimit"

	bt_smc_stub | sed "s#@BT_ROOT@#$T#g" >"$T/bin/smc"
	command chmod 755 "$T/bin/smc"
	bt_stub_block | sed "s#@BT_ROOT@#$T#g" >"$T/stubs.sh"

	# Rewrite system paths, then inject the stubs after the first top-level `fi`
	# (the end of the PATH block).
	sed -e "s#/usr/local/co\\\\\\.battery-optimizer#$T/bin#g" \
		-e "s#/usr/local/co\\.battery-optimizer#$T/bin#g" \
		-e "s#/usr/local/bin#$T/usrlocalbin#g" \
		-e "s#/private/etc/sudoers\\.d#$T/sudoers.d#g" \
		-e "s#/etc/paths\\.d/#$T/paths.d/#g" \
		-e "s#/opt/homebrew/bin:/opt/homebrew/sbin:##g" \
		"$src" | awk -v stubs="$T/stubs.sh" '
			{ print }
			!done && /^fi$/ { while ((getline l < stubs) > 0) print l; done = 1 }
		' >"$T/bin/battery"
	command chmod 755 "$T/bin/battery"
	bt_selfcheck
}

# Hard self-checks. Any failure aborts the whole run before the copy executes.
bt_selfcheck() {
	local copy="$T/bin/battery" bad
	grep -q "BEGIN TEST HARNESS STUBS" "$copy" || bt_abort "stub block was not injected"
	bad="$(grep -v '^[[:space:]]*#' "$copy" | grep -n -E '/usr/local/|/opt/homebrew|/private/etc|/etc/sudoers|/etc/paths\.d|/Applications/|co\.palokaj' || true)"
	[[ -z "$bad" ]] || bt_abort "rewritten copy still references real paths:
$bad"
	bad="$(grep -v '^[[:space:]]*#' "$copy" | grep -n '/Library/LaunchAgents' | grep -v '\$HOME/Library/LaunchAgents' || true)"
	[[ -z "$bad" ]] || bt_abort "rewritten copy writes LaunchAgents outside \$HOME: $bad"
	grep -q "$BT_REAL_HOME/" "$copy" && bt_abort "rewritten copy names the real home"
	grep -q '/usr/local/co.battery-optimizer/smc\|/usr/local/bin/smc' "$copy" && bt_abort "rewritten copy names a real smc"
	# The injected block must make `sudo` a function.
	local kind
	kind="$(env -i HOME="$T/home" PATH=/usr/bin:/bin /bin/bash -c "source '$T/stubs.sh'; type -t sudo; type -t kill; type -t pmset")"
	[[ "$kind" == $'function\nfunction\nfunction' ]] || bt_abort "stubs do not shadow sudo/kill/pmset (got: $kind)"
	grep -qx "binfolder=$T/bin" "$copy" || bt_abort "binfolder was not rewritten to the test root"
	grep -qx 'smc_binary="$binfolder/smc"' "$copy" || bt_abort "smc_binary is not derived from the rewritten binfolder"
}

# bt_run <timeout seconds> <battery args...>
# Runs the copy with a clean environment. Sets BT_RC, BT_OUT, BT_ERR, BT_TIMED_OUT.
bt_run() {
	local to="$1" pid ticks=0
	shift
	BT_TIMED_OUT=0
	env -i HOME="$T/home" USER="$(id -un)" LOGNAME="$(id -un)" PATH=/usr/bin:/bin:/usr/sbin:/sbin \
		TMPDIR="$T/tmp" LANG=en_US.UTF-8 \
		BT_SLEEP_MAX="${BT_SLEEP_MAX:-0.05}" BT_CURL_MODE="${BT_CURL_MODE:-fail}" \
		BT_OSA_ANSWER="${BT_OSA_ANSWER:-No}" BT_VISUDO_RC="${BT_VISUDO_RC:-0}" \
		/bin/bash "$T/bin/battery" "$@" </dev/null >"$T/out" 2>"$T/err" &
	pid=$!
	while kill -0 "$pid" 2>/dev/null; do
		if ((ticks >= to * 10)); then
			BT_TIMED_OUT=1
			kill -TERM "$pid" 2>/dev/null
			break
		fi
		command sleep 0.1
		ticks=$((ticks + 1))
	done
	wait "$pid"
	BT_RC=$?
	BT_OUT="$(cat "$T/out")"
	BT_ERR="$(cat "$T/err")"
}

# bt_start_bg <battery args...>: start the copy in the background; PID in BT_BG_PID.
bt_start_bg() {
	env -i HOME="$T/home" USER="$(id -un)" LOGNAME="$(id -un)" PATH=/usr/bin:/bin:/usr/sbin:/sbin \
		TMPDIR="$T/tmp" LANG=en_US.UTF-8 \
		BT_SLEEP_MAX="${BT_SLEEP_MAX:-0.05}" BT_CURL_MODE="${BT_CURL_MODE:-fail}" \
		BT_OSA_ANSWER="${BT_OSA_ANSWER:-No}" BT_VISUDO_RC="${BT_VISUDO_RC:-0}" \
		/bin/bash "$T/bin/battery" "$@" </dev/null >"$T/out" 2>"$T/err" &
	BT_BG_PID=$!
}

# bt_wait_for <seconds> <file> <fixed string>: poll until the file contains the string.
bt_wait_for() {
	local to="$1" file="$2" str="$3" ticks=0
	while ! grep -qF -- "$str" "$file" 2>/dev/null; do
		((ticks >= to * 10)) && return 1
		command sleep 0.1
		ticks=$((ticks + 1))
	done
	return 0
}

# Start a harmless dummy process the test may legitimately see killed.
bt_dummy() {
	# Started in a subshell so it is not a job of this shell (no "Terminated" noise).
	BT_DUMMY_PID="$(command sleep 300 >/dev/null 2>&1 & echo $!)"
	echo "$BT_DUMMY_PID" >>"$T/killable"
}

bt_teardown() {
	local root="${1:-$T}" p
	[[ -n "$root" && -d "$root" ]] || return 0
	case "$root" in "$BT_BASE"/bt.*) ;; *) echo "refusing to tear down $root" >&2; return 1 ;; esac
	# Stop any copy still running from this root (the pattern is the unique temp path).
	/usr/bin/pkill -TERM -f "$root/" 2>/dev/null
	if [[ -f "$root/killable" ]]; then
		while read -r p; do [[ "$p" =~ ^[0-9]+$ ]] && kill "$p" 2>/dev/null; done <"$root/killable"
	fi
	if [[ -z "${BT_KEEP:-}" ]]; then rm -rf "$root"; fi
}

bt_teardown_all() {
	local r
	for r in "${BT_ALL_ROOTS[@]}"; do bt_teardown "$r"; done
}

# ---- tiny assertion helpers ----
BT_PASS=0
BT_FAIL=0
BT_FAILED_NAMES=()
ok() {
	BT_PASS=$((BT_PASS + 1))
	echo "ok   - $1"
}
not_ok() {
	BT_FAIL=$((BT_FAIL + 1))
	BT_FAILED_NAMES+=("$1")
	echo "FAIL - $1"
	[[ -n "${2:-}" ]] && echo "$2" | sed 's/^/       | /'
	return 0
}
check() { # check <name> <command...>
	local name="$1"
	shift
	if "$@"; then ok "$name"; else not_ok "$name" "rc=$BT_RC out: $(echo "$BT_OUT" | tail -n 5)
err: $(echo "$BT_ERR" | tail -n 3)
smc writes: $(tail -n 5 "$T/smc_writes.log" 2>/dev/null)"; fi
}
