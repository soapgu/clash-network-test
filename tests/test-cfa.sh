#!/usr/bin/env bash
set -eu

PROJECT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/cfa-entry-test.XXXXXX")
trap 'rm -rf "$TEST_ROOT"' EXIT INT TERM

BIN_DIR="$TEST_ROOT/bin"
STATE_DIR="$TEST_ROOT/state"
REPORT_DIR="$TEST_ROOT/reports"
OUTPUT_DIR="$TEST_ROOT/outputs"
SOURCE="$TEST_ROOT/手机 导出的配置.yaml.txt"
mkdir -p "$BIN_DIR"

cat > "$BIN_DIR/dig" <<'EOF'
#!/usr/bin/env bash
case " $* " in
  *" NS "*) printf 'ns.example.test.\n' ;;
  *" AAAA ipv6.example.test "*) printf '2001:db8::1\n' ;;
  *" AAAA "*) ;;
  *" A ipv6.example.test "*|*" A noipv4.example.test "*) ;;
  *" A single.example.test "*) printf '10.0.0.1\n' ;;
  *) printf '192.0.2.10\n198.51.100.20\n' ;;
esac
EOF

cat > "$BIN_DIR/nc" <<'EOF'
#!/usr/bin/env bash
case " $* " in
  *198.51.100.20*) exit 0 ;;
  *) exit 1 ;;
esac
EOF

cat > "$BIN_DIR/dscacheutil" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$BIN_DIR/dig" "$BIN_DIR/nc" "$BIN_DIR/dscacheutil"

export PATH="$BIN_DIR:$PATH"
export CFA_ENTRY_STATE_DIR="$STATE_DIR"
export CFA_ENTRY_REPORT_DIR="$REPORT_DIR"
export CFA_ENTRY_OUTPUT_DIR="$OUTPUT_DIR"
export CFA_ENTRY_SAMPLE_PORTS=3
export CFA_ENTRY_TEST_ROUNDS=2
export CFA_ENTRY_MAX_CONCURRENCY=2

write_normal() {
  cat > "$SOURCE" <<'EOF'
mixed-port: 7890
dns:
  nameserver:
    - 223.5.5.5
proxies:
  - {name: 官网地址 - https://example.com, server: www.baidu.com, port: 80, type: ssr, note: bad:yaml}
  - {name: 剩余流量：80%, server: www.baidu.com, port: 80, type: ssr}
  - {name: 节点01, server: entry.example.test, port: 7001, type: ssr, password: secret-a}
  - {name: 节点02, server: entry.example.test, port: 7002, type: ssr, password: secret-b}
  - {name: 节点03, server: entry.example.test, port: 9051, type: ssr, password: secret-c}
  - {name: 节点引号, server: "entry.example.test", port: 7003, type: ssr, password: secret-q}
  - name: 节点04
    server: entry.example.test
    port: 7004
    type: ssr
    password: secret-d
proxy-groups:
  - name: 自动选择
    type: select
    proxies: [节点01, 节点02]
rules:
  - MATCH,自动选择
EOF
}

reason() { awk -F '\t' '$1=="# skip_reason"{print $2;exit}' "$STATE_DIR/cfa-latest-report.tsv"; }
status_value() { awk -F '\t' '$1=="# status"{print $2;exit}' "$STATE_DIR/cfa-latest-report.tsv"; }

write_normal
"$PROJECT_DIR/cfa-entry-ip.sh" diagnose "$SOURCE" >/dev/null
[ "$(status_value)" = testable ]
awk -F '\t' '$1=="198.51.100.20"&&$2=="yes"{ok=1}END{exit !ok}' "$STATE_DIR/cfa-latest-report.tsv"
awk -F '\t' '$1=="192.0.2.10"&&$2=="no"{ok=1}END{exit !ok}' "$STATE_DIR/cfa-latest-report.tsv"
grep -q $'^# tested_ports\t.*9051' "$STATE_DIR/cfa-latest-report.tsv"
grep -q $'^# real_nodes\t5$' "$STATE_DIR/cfa-latest-report.tsv"
grep -q $'^# replacement_nodes\t5$' "$STATE_DIR/cfa-latest-report.tsv"

if "$PROJECT_DIR/cfa-entry-ip.sh" apply 192.0.2.10 >/dev/null 2>&1; then
  printf '不合格 IP 不应允许应用\n' >&2;exit 1
fi

"$PROJECT_DIR/cfa-entry-ip.sh" apply 198.51.100.20 >/dev/null
OUTPUT=$(awk -F '\t' '$1=="output_path"{print $2}' "$STATE_DIR/cfa-latest-output.tsv")
[ -f "$OUTPUT" ]
case "$OUTPUT" in "$OUTPUT_DIR"/*.yaml) ;;*)printf '输出路径或扩展名错误\n' >&2;exit 1;;esac
[ "$(stat -f '%Lp' "$OUTPUT")" = 600 ]
[ "$(grep -c 'server: 198.51.100.20' "$OUTPUT")" -eq 4 ]
grep -q 'server: "198.51.100.20"' "$OUTPUT"
! grep -q 'server: entry.example.test' "$OUTPUT"
grep -q 'server: www.baidu.com' "$OUTPUT"
grep -q 'password: secret-a' "$OUTPUT"
grep -q 'note: bad:yaml' "$OUTPUT"
cmp <(sed 's/server: entry.example.test/server: 198.51.100.20/g;s/server: "entry.example.test"/server: "198.51.100.20"/g' "$SOURCE") "$OUTPUT"

"$PROJECT_DIR/cfa-entry-ip.sh" apply 198.51.100.20 >/dev/null
OUTPUT2=$(awk -F '\t' '$1=="output_path"{print $2}' "$STATE_DIR/cfa-latest-output.tsv")
[ "$OUTPUT" != "$OUTPUT2" ]
[ -f "$OUTPUT2" ]
"$PROJECT_DIR/cfa-entry-ip.sh" status > "$TEST_ROOT/status.txt"
grep -q '源文件状态：未变化' "$TEST_ROOT/status.txt"
grep -q '报告时效：有效' "$TEST_ROOT/status.txt"
grep -q '输出状态：存在' "$TEST_ROOT/status.txt"

# 应用阶段：源文件改变、消失、报告过期和没有报告时拒绝。
write_normal
"$PROJECT_DIR/cfa-entry-ip.sh" diagnose "$SOURCE" >/dev/null
printf '\n# changed\n' >> "$SOURCE"
if "$PROJECT_DIR/cfa-entry-ip.sh" apply 198.51.100.20 >/dev/null 2>&1;then printf '源文件改变后不应允许应用\n' >&2;exit 1;fi

write_normal
"$PROJECT_DIR/cfa-entry-ip.sh" diagnose "$SOURCE" >/dev/null
mv "$SOURCE" "$SOURCE.moved"
if "$PROJECT_DIR/cfa-entry-ip.sh" apply 198.51.100.20 >/dev/null 2>&1;then printf '源文件消失后不应允许应用\n' >&2;exit 1;fi
mv "$SOURCE.moved" "$SOURCE"

"$PROJECT_DIR/cfa-entry-ip.sh" diagnose "$SOURCE" >/dev/null
sed 's/^# generated_epoch.*/# generated_epoch\t1/' "$STATE_DIR/cfa-latest-report.tsv" > "$TEST_ROOT/expired"
mv "$TEST_ROOT/expired" "$STATE_DIR/cfa-latest-report.tsv"
if "$PROJECT_DIR/cfa-entry-ip.sh" apply 198.51.100.20 >/dev/null 2>&1;then printf '过期报告不应允许应用\n' >&2;exit 1;fi

rm "$STATE_DIR/cfa-latest-report.tsv"
if "$PROJECT_DIR/cfa-entry-ip.sh" apply 198.51.100.20 >/dev/null 2>&1;then printf '没有报告时不应允许应用\n' >&2;exit 1;fi

assert_skip() {
  expected=$1
  "$PROJECT_DIR/cfa-entry-ip.sh" diagnose "$SOURCE" >/dev/null
  [ "$(status_value)" = skipped ]
  [ "$(reason)" = "$expected" ]
  if "$PROJECT_DIR/cfa-entry-ip.sh" apply 198.51.100.20 >/dev/null 2>&1;then printf '跳过报告不应允许应用：%s\n' "$expected" >&2;exit 1;fi
}

# 诊断阶段跳过不满足统一入口检测条件的配置。
cat > "$SOURCE" <<'EOF'
proxies:
- {name: A, server: 10.0.0.1, port: 443}
EOF
assert_skip fixed_ip

cat > "$SOURCE" <<'EOF'
proxies:
- {name: A, server: 10.0.0.1, port: 443}
- {name: B, server: 10.0.0.2, port: 443}
EOF
assert_skip multiple_ips

cat > "$SOURCE" <<'EOF'
proxies:
- {name: A, server: a.example.test, port: 443}
- {name: B, server: b.example.test, port: 443}
EOF
assert_skip multiple_domains

cat > "$SOURCE" <<'EOF'
proxies:
- {name: A, server: a.example.test, port: 443}
- {name: B, server: 10.0.0.2, port: 443}
EOF
assert_skip mixed_endpoints

cat > "$SOURCE" <<'EOF'
proxies:
- {name: A, server: ipv6.example.test, port: 443}
EOF
assert_skip ipv6_only

cat > "$SOURCE" <<'EOF'
proxies:
- {name: A, server: noipv4.example.test, port: 443}
EOF
assert_skip no_ipv4

cat > "$SOURCE" <<'EOF'
proxies:
- {name: A, server: single.example.test, port: 443}
EOF
assert_skip single_dns_ip

printf 'CFA 测试通过\n'
