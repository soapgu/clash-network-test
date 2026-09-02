#!/usr/bin/env bash
set -eu

PROJECT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/clash-monitor-test.XXXXXX")
trap 'rm -rf "$TEST_ROOT"' EXIT INT TERM

APP_DIR="$TEST_ROOT/app"
BIN_DIR="$TEST_ROOT/bin"
STATE_DIR="$TEST_ROOT/state"
REPORT_DIR="$TEST_ROOT/reports"
BACKUP_DIR="$TEST_ROOT/backups"
AGENT_DIR="$TEST_ROOT/LaunchAgents"
mkdir -p "$APP_DIR/profiles" "$BIN_DIR"

cat >"$APP_DIR/clash-verge.yaml" <<'EOF'
mixed-port: 7897
external-controller-unix: /tmp/fake-mihomo.sock
dns:
  nameserver:
  - 223.5.5.5
proxies:
- name: 节点一
  server: entry.example.test
  port: 9051
- name: 节点二
  server: entry.example.test
  port: 7001
proxy-groups: []
EOF
cat >"$APP_DIR/config.yaml" <<'EOF'
external-controller-unix: /tmp/fake-mihomo.sock
EOF
cat >"$APP_DIR/profiles.yaml" <<'EOF'
current: main
items:
- uid: script-main
  type: script
  file: main.js
- uid: main
  type: remote
  name: 监测测试订阅
  file: main.yaml
  option:
    script: script-main
EOF
cat >"$APP_DIR/profiles/main.js" <<'EOF'
function main(config, profileName) {
  return config;
}
EOF
cat >"$APP_DIR/profiles/main.yaml" <<'EOF'
proxies:
- {name: 节点一, server: entry.example.test, port: 9051}
- {name: 节点二, server: entry.example.test, port: 7001}
proxy-groups: []
EOF

cat >"$BIN_DIR/dig" <<'EOF'
#!/usr/bin/env bash
case " $* " in *" NS "*) printf 'ns.example.test.\n';;*) printf '192.0.2.10\n198.51.100.20\n';;esac
EOF
cat >"$BIN_DIR/nc" <<'EOF'
#!/usr/bin/env bash
case " $* " in
 *198.51.100.20*) [ "${CLASH_TEST_ENTRY_DOWN:-0}" != 1 ];;
 *192.0.2.10*) [ "${CLASH_TEST_ENTRY_DOWN:-0}" = 1 ];;
 *) exit 1;;
esac
EOF
cat >"$BIN_DIR/curl" <<'EOF'
#!/usr/bin/env bash
printf '<%s>\n' "$@" >>"${CLASH_TEST_CURL_LOG:?}"
case " $* " in
 *baidu.com*) key=baidu;;*taobao.com*) key=taobao;;*qq.com*) key=qq;;
 *--write-out*) printf '204';exit 0;;
 */version*) printf '{"version":"test"}';exit 0;;
 *'-X PUT'*/configs*) printf '{}';exit 0;;
 */configs*) printf '{}';exit 0;;
 *) printf '{}';exit 0;;
esac
mode=${CLASH_TEST_CONNECTIVITY_MODE:-all}
case "$mode:$key" in
 all:*) code=204;;two:qq) code=503;;two:*) code=204;;one:baidu) code=403;;one:*) code=503;;none:*) code=000;;codes:baidu) code=403;;codes:taobao) code=499;;codes:qq) code=503;;esac
[ "$code" = 000 ]&&exit 1
printf '%s' "$code"
EOF
cat >"$BIN_DIR/dscacheutil" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
cat >"$BIN_DIR/osascript" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${CLASH_TEST_NOTIFICATION_LOG:?}"
EOF
cat >"$BIN_DIR/launchctl" <<'EOF'
#!/usr/bin/env bash
state=${CLASH_TEST_LAUNCHCTL_STATE:?}
case "$1" in
 bootstrap) printf 'loaded\n' >"$state";;
 bootout) rm -f "$state";;
 print) [ -f "$state" ];;
 *) exit 1;;
esac
EOF
chmod +x "$BIN_DIR"/*

export PATH="$BIN_DIR:$PATH"
export CLASH_APP_DIR="$APP_DIR"
export CLASH_ENTRY_STATE_DIR="$STATE_DIR"
export CLASH_ENTRY_REPORT_DIR="$REPORT_DIR"
export CLASH_ENTRY_BACKUP_DIR="$BACKUP_DIR"
export CLASH_ENTRY_LAUNCH_AGENT_DIR="$AGENT_DIR"
export CLASH_ENTRY_SAMPLE_PORTS=2
export CLASH_ENTRY_TEST_ROUNDS=2
export CLASH_ENTRY_MAX_CONCURRENCY=2
export CLASH_ENTRY_FAIL_THRESHOLD=3
export CLASH_TEST_CURL_LOG="$TEST_ROOT/curl.log"
export CLASH_TEST_NOTIFICATION_LOG="$TEST_ROOT/notifications.log"
export CLASH_TEST_LAUNCHCTL_STATE="$TEST_ROOT/launchctl.state"
:>"$CLASH_TEST_CURL_LOG";:>"$CLASH_TEST_NOTIFICATION_LOG"

value(){ awk -F '\t' -v key="$1" '$1==key{print $2;exit}' "$STATE_DIR/monitor-state.tsv"; }

"$PROJECT_DIR/clash-entry-ip.sh" diagnose >/dev/null
"$PROJECT_DIR/clash-entry-ip.sh" apply 198.51.100.20 >/dev/null

CLASH_TEST_CONNECTIVITY_MODE=all "$PROJECT_DIR/clash-entry-ip.sh" switch >"$TEST_ROOT/switch-optimal.txt"
grep -q '当前 IP 198.51.100.20 已经是最优选择，无需切换' "$TEST_ROOT/switch-optimal.txt"

CLASH_TEST_CONNECTIVITY_MODE=all "$PROJECT_DIR/clash-entry-ip.sh" health >/dev/null
[ "$(value status)" = healthy ];[ "$(value internet_success)" = 3 ]
grep -q '^<--noproxy>$' "$CLASH_TEST_CURL_LOG"
grep -q '^<\*>$' "$CLASH_TEST_CURL_LOG"

CLASH_TEST_CONNECTIVITY_MODE=codes "$PROJECT_DIR/clash-entry-ip.sh" health >/dev/null
[ "$(value status)" = healthy ];[ "$(value internet_success)" = 2 ]

CLASH_TEST_ENTRY_DOWN=1 CLASH_TEST_CONNECTIVITY_MODE=all "$PROJECT_DIR/clash-entry-ip.sh" health >/dev/null
[ "$(value status)" = entry_suspected ];[ "$(value consecutive_failures)" = 1 ]
CLASH_TEST_ENTRY_DOWN=1 CLASH_TEST_CONNECTIVITY_MODE=one "$PROJECT_DIR/clash-entry-ip.sh" health >/dev/null
[ "$(value status)" = internet_uncertain ];[ "$(value consecutive_failures)" = 1 ]
CLASH_TEST_ENTRY_DOWN=1 CLASH_TEST_CONNECTIVITY_MODE=none "$PROJECT_DIR/clash-entry-ip.sh" health >/dev/null
[ "$(value status)" = internet_down ];[ "$(value consecutive_failures)" = 1 ]

CLASH_TEST_ENTRY_DOWN=1 CLASH_TEST_CONNECTIVITY_MODE=two "$PROJECT_DIR/clash-entry-ip.sh" monitor __check >/dev/null
[ "$(value status)" = entry_suspected ];[ "$(value consecutive_failures)" = 2 ]
CLASH_TEST_ENTRY_DOWN=1 CLASH_TEST_CONNECTIVITY_MODE=all "$PROJECT_DIR/clash-entry-ip.sh" monitor __check >/dev/null
[ "$(value status)" = entry_down ];[ "$(value recommended_ip)" = 192.0.2.10 ]
[ "$(wc -l<"$CLASH_TEST_NOTIFICATION_LOG"|tr -d ' ')" = 1 ]
CLASH_TEST_ENTRY_DOWN=1 CLASH_TEST_CONNECTIVITY_MODE=all "$PROJECT_DIR/clash-entry-ip.sh" monitor __check >/dev/null
[ "$(wc -l<"$CLASH_TEST_NOTIFICATION_LOG"|tr -d ' ')" = 1 ]

before=$(shasum -a 256 "$APP_DIR/profiles/main.js"|awk '{print $1}')
printf 'n\n'|CLASH_TEST_ENTRY_DOWN=1 CLASH_TEST_CONNECTIVITY_MODE=all "$PROJECT_DIR/clash-entry-ip.sh" switch >/dev/null
[ "$before" = "$(shasum -a 256 "$APP_DIR/profiles/main.js"|awk '{print $1}')" ]
if printf 'y\n'|CLASH_TEST_CONNECTIVITY_MODE=none "$PROJECT_DIR/clash-entry-ip.sh" switch >/dev/null 2>&1;then printf '断网时不应允许切换\n' >&2;exit 1;fi
printf 'y\n'|CLASH_TEST_ENTRY_DOWN=1 CLASH_TEST_CONNECTIVITY_MODE=all "$PROJECT_DIR/clash-entry-ip.sh" switch >/dev/null
grep -q 'const pinnedIp = "192.0.2.10"' "$APP_DIR/profiles/main.js"

"$PROJECT_DIR/clash-entry-ip.sh" monitor install >/dev/null
[ -f "$AGENT_DIR/com.clash-entry-ip.monitor.plist" ];[ -f "$CLASH_TEST_LAUNCHCTL_STATE" ]
grep -q '<integer>60</integer>' "$AGENT_DIR/com.clash-entry-ip.monitor.plist"
"$PROJECT_DIR/clash-entry-ip.sh" monitor status >"$TEST_ROOT/monitor-status.txt"
grep -q '后台监测：运行中' "$TEST_ROOT/monitor-status.txt"
"$PROJECT_DIR/clash-entry-ip.sh" monitor uninstall >/dev/null
[ ! -f "$AGENT_DIR/com.clash-entry-ip.monitor.plist" ];[ ! -f "$CLASH_TEST_LAUNCHCTL_STATE" ]

printf '监测测试通过\n'
