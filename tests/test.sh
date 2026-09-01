#!/usr/bin/env bash

set -eu

PROJECT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/clash-entry-test.XXXXXX")
trap 'rm -rf "$TEST_ROOT"' EXIT INT TERM

APP_DIR="$TEST_ROOT/app"
BIN_DIR="$TEST_ROOT/bin"
STATE_DIR="$TEST_ROOT/state"
REPORT_DIR="$TEST_ROOT/reports"
BACKUP_DIR="$TEST_ROOT/backups"
mkdir -p "$APP_DIR/profiles" "$BIN_DIR"

cat > "$APP_DIR/clash-verge.yaml" <<'EOF'
mixed-port: 7897
external-controller: ''
external-controller-unix: /tmp/fake-mihomo.sock
dns:
  nameserver:
  - 223.5.5.5
proxies:
- name: 日本01
  server: entry.example.test
  port: 9051
  type: ssr
- name: 香港01
  server: entry.example.test
  port: 7001
  type: ssr
- name: 美国01
  server: entry.example.test
  port: 7002
  type: ssr
proxy-groups: []
EOF

cat > "$APP_DIR/config.yaml" <<'EOF'
external-controller-unix: /tmp/fake-mihomo.sock
EOF

cat > "$APP_DIR/profiles.yaml" <<'EOF'
current: main
items:
- uid: script-main
  type: script
  file: main.js
- uid: main
  type: remote
  name: 当前测试订阅
  file: main.yaml
  option:
    script: script-main
- uid: script-backup
  type: script
  file: backup.js
- uid: backup
  type: remote
  name: 备用测试订阅
  file: backup.yaml
  option:
    script: script-backup
EOF

for file in main.js backup.js; do
  cat > "$APP_DIR/profiles/$file" <<'EOF'
// Define main function (script entry)

function main(config, profileName) {
  return config;
}
EOF
done

cat > "$APP_DIR/profiles/main.yaml" <<'EOF'
proxies:
- {name: 官网地址 - https://example.com, server: placeholder.example, port: 80, type: ssr, note: bad:yaml}
- {name: 日本01, server: entry.example.test, port: 9051, type: ssr}
- {name: 香港01, server: entry.example.test, port: 7001, type: ssr}
- {name: 美国01, server: entry.example.test, port: 7002, type: ssr}
proxy-groups: []
EOF
cp "$APP_DIR/profiles/main.yaml" "$APP_DIR/profiles/backup.yaml"

cat > "$BIN_DIR/dig" <<'EOF'
#!/usr/bin/env bash
case " $* " in
  *" NS "*) printf 'vip7.alidns.com.\n' ;;
  *single.example*) printf '10.0.0.1\n' ;;
  *) printf '192.0.2.10\n198.51.100.20\n' ;;
esac
EOF

cat > "$BIN_DIR/nc" <<'EOF'
#!/usr/bin/env bash
case " $* " in
  *192.0.2.10*) exit 1 ;;
  *198.51.100.20*) exit 0 ;;
  *) exit 1 ;;
esac
EOF

cat > "$BIN_DIR/curl" <<'EOF'
#!/usr/bin/env bash
case " $* " in
  *--write-out*) [ "${CLASH_TEST_FAIL_SMOKE:-0}" = 1 ] && exit 1; printf '204' ;;
  */version*) [ "${CLASH_TEST_CONTROLLER_DOWN:-0}" = 1 ] && exit 1; printf '{"version":"test"}' ;;
  *'-X PUT'*/configs*) [ "${CLASH_TEST_FAIL_RELOAD:-0}" = 1 ] && exit 1; printf '{}' ;;
  */configs*) printf '{}' ;;
  *) printf '{}' ;;
esac
EOF

cat > "$BIN_DIR/dscacheutil" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF

chmod +x "$BIN_DIR/dig" "$BIN_DIR/nc" "$BIN_DIR/curl" "$BIN_DIR/dscacheutil"

export PATH="$BIN_DIR:$PATH"
export CLASH_APP_DIR="$APP_DIR"
export CLASH_ENTRY_STATE_DIR="$STATE_DIR"
export CLASH_ENTRY_REPORT_DIR="$REPORT_DIR"
export CLASH_ENTRY_BACKUP_DIR="$BACKUP_DIR"
export CLASH_ENTRY_SAMPLE_PORTS=2
export CLASH_ENTRY_TEST_ROUNDS=5
export CLASH_ENTRY_MAX_CONCURRENCY=2

"$PROJECT_DIR/clash-entry-ip.sh" diagnose >/dev/null

"$PROJECT_DIR/clash-entry-ip.sh" status > "$TEST_ROOT/status.txt"
grep -q 'Mihomo控制接口：可用' "$TEST_ROOT/status.txt"
grep -q '最近报告：testable' "$TEST_ROOT/status.txt"

awk -F '\t' '$1=="198.51.100.20" && $2=="yes" {ok=1} END{exit !ok}' "$STATE_DIR/latest-report.tsv"
awk -F '\t' '$1=="192.0.2.10" && $2=="no" {ok=1} END{exit !ok}' "$STATE_DIR/latest-report.tsv"
grep -q $'^# tested_ports\t.*9051' "$STATE_DIR/latest-report.tsv"
awk -F '\t' '$1=="198.51.100.20" && $4==10 {ok=1} END{exit !ok}' "$STATE_DIR/latest-report.tsv"

if "$PROJECT_DIR/clash-entry-ip.sh" apply 192.0.2.10 >/dev/null 2>&1; then
  printf '不稳定IP不应允许应用\n' >&2
  exit 1
fi

cp "$STATE_DIR/latest-report.tsv" "$TEST_ROOT/report.backup"
sed 's/^# generated_epoch.*/# generated_epoch\t1/' "$TEST_ROOT/report.backup" > "$STATE_DIR/latest-report.tsv"
if "$PROJECT_DIR/clash-entry-ip.sh" apply 198.51.100.20 >/dev/null 2>&1; then
  printf '过期报告不应允许应用\n' >&2
  exit 1
fi
cp "$TEST_ROOT/report.backup" "$STATE_DIR/latest-report.tsv"

"$PROJECT_DIR/clash-entry-ip.sh" apply 198.51.100.20 >/dev/null
grep -q 'const pinnedIp = "198.51.100.20"' "$APP_DIR/profiles/main.js"
if grep -q 'pinnedIp' "$APP_DIR/profiles/backup.js"; then
  printf '不应修改非当前订阅脚本\n' >&2
  exit 1
fi
grep -q 'server: 198.51.100.20' "$APP_DIR/clash-verge.yaml"
"$PROJECT_DIR/clash-entry-ip.sh" apply 198.51.100.20 >/dev/null
[ "$(grep -c 'CLASH_ENTRY_IP_MANAGED_BEGIN' "$APP_DIR/profiles/main.js")" -eq 1 ]

# 原始订阅仍是域名，运行配置只含锁定IP时仍可重新诊断。
"$PROJECT_DIR/clash-entry-ip.sh" diagnose >/dev/null
awk -F '\t' '$1=="198.51.100.20" && $2=="yes" {ok=1} END{exit !ok}' "$STATE_DIR/latest-report.tsv"

# 允许第二个候选 IP，用于验证连续切换后 reset 直接恢复原始域名。
awk -F '\t' 'BEGIN{OFS="\t"}$1=="192.0.2.10"{$2="yes"}{print}' "$STATE_DIR/latest-report.tsv" > "$TEST_ROOT/report.switch"
cp "$TEST_ROOT/report.switch" "$STATE_DIR/latest-report.tsv"
"$PROJECT_DIR/clash-entry-ip.sh" apply 192.0.2.10 >/dev/null
sed '/^proxy-groups:/i\
- name: 新增节点\
  server: updated.example.test\
  port: 8443' "$APP_DIR/clash-verge.yaml" > "$TEST_ROOT/runtime.updated"
cp "$TEST_ROOT/runtime.updated" "$APP_DIR/clash-verge.yaml"
sed '/^proxy-groups:/i\
- name: 新增节点\
  server: updated.example.test\
  port: 8443' "$APP_DIR/profiles/main.yaml" > "$TEST_ROOT/profile.updated"
cp "$TEST_ROOT/profile.updated" "$APP_DIR/profiles/main.yaml"

"$PROJECT_DIR/clash-entry-ip.sh" reset >/dev/null
grep -q 'server: entry.example.test' "$APP_DIR/clash-verge.yaml"
grep -q 'server: updated.example.test' "$APP_DIR/clash-verge.yaml"
if grep -q 'CLASH_ENTRY_IP_MANAGED_BEGIN' "$APP_DIR/profiles/main.js"; then
  printf 'reset 未移除脚本锁定\n' >&2
  exit 1
fi
"$PROJECT_DIR/clash-entry-ip.sh" status > "$TEST_ROOT/status.reset.txt"
grep -q '入口锁定：未锁定' "$TEST_ROOT/status.reset.txt"
"$PROJECT_DIR/clash-entry-ip.sh" reset > "$TEST_ROOT/reset-again.txt"
grep -q '无需恢复' "$TEST_ROOT/reset-again.txt"

# reset 本身可由 rollback 撤销。
"$PROJECT_DIR/clash-entry-ip.sh" rollback >/dev/null
grep -q 'const pinnedIp = "192.0.2.10"' "$APP_DIR/profiles/main.js"
grep -q 'server: 192.0.2.10' "$APP_DIR/clash-verge.yaml"
grep -q 'server: updated.example.test' "$APP_DIR/clash-verge.yaml"

# reset 各失败路径均不得留下半恢复状态。
for failure in CLASH_TEST_CONTROLLER_DOWN CLASH_TEST_FAIL_RELOAD CLASH_TEST_FAIL_SMOKE; do
  before_script=$(shasum -a 256 "$APP_DIR/profiles/main.js" | awk '{print $1}')
  before_runtime=$(shasum -a 256 "$APP_DIR/clash-verge.yaml" | awk '{print $1}')
  if env "$failure=1" "$PROJECT_DIR/clash-entry-ip.sh" reset >/dev/null 2>&1; then
    printf '%s 时 reset 不应成功\n' "$failure" >&2
    exit 1
  fi
  [ "$before_script" = "$(shasum -a 256 "$APP_DIR/profiles/main.js" | awk '{print $1}')" ]
  [ "$before_runtime" = "$(shasum -a 256 "$APP_DIR/clash-verge.yaml" | awk '{print $1}')" ]
done

"$PROJECT_DIR/clash-entry-ip.sh" reset >/dev/null
grep -q 'server: entry.example.test' "$APP_DIR/clash-verge.yaml"
grep -q 'server: updated.example.test' "$APP_DIR/clash-verge.yaml"

assert_skip() {
  expected=$1
  "$PROJECT_DIR/clash-entry-ip.sh" diagnose >/dev/null
  [ "$(awk -F '\t' '$1=="# status"{print $2}' "$STATE_DIR/latest-report.tsv")" = skipped ]
  [ "$(awk -F '\t' '$1=="# skip_reason"{print $2}' "$STATE_DIR/latest-report.tsv")" = "$expected" ]
}

cat > "$APP_DIR/profiles/main.yaml" <<'EOF'
proxies:
- name: 固定入口
  server: 10.0.0.1
  port: 443
proxy-groups: []
EOF
assert_skip fixed_ip

cat > "$APP_DIR/profiles/main.yaml" <<'EOF'
proxies:
- {name: A, server: 10.0.0.1, port: 443}
- {name: B, server: 10.0.0.2, port: 443}
proxy-groups: []
EOF
assert_skip multiple_ips

cat > "$APP_DIR/profiles/main.yaml" <<'EOF'
proxies:
- {name: A, server: api.example.com, port: 443}
- {name: B, server: 10.0.0.2, port: 443}
proxy-groups: []
EOF
assert_skip mixed_endpoints

cat > "$APP_DIR/profiles/main.yaml" <<'EOF'
proxies:
- {name: A, server: a.example.com, port: 443}
- {name: B, server: b.example.com, port: 443}
proxy-groups: []
EOF
assert_skip multiple_domains

cat > "$APP_DIR/profiles/main.yaml" <<'EOF'
proxies:
- {name: A, server: single.example, port: 443}
proxy-groups: []
EOF
assert_skip single_dns_ip

if "$PROJECT_DIR/clash-entry-ip.sh" apply 10.0.0.1 >/dev/null 2>&1; then
  printf '跳过报告不应允许应用\n' >&2
  exit 1
fi

printf '测试通过\n'
