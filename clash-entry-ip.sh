#!/usr/bin/env bash
set -u

APP_DIR="${CLASH_APP_DIR:-$HOME/Library/Application Support/io.github.clash-verge-rev.clash-verge-rev}"
RUNTIME_CONFIG="${CLASH_RUNTIME_CONFIG:-$APP_DIR/clash-verge.yaml}"
BASE_CONFIG="${CLASH_BASE_CONFIG:-$APP_DIR/config.yaml}"
PROFILES_CONFIG="${CLASH_PROFILES_CONFIG:-$APP_DIR/profiles.yaml}"
PROJECT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
STATE_DIR="${CLASH_ENTRY_STATE_DIR:-$PROJECT_DIR/.state}"
REPORT_DIR="${CLASH_ENTRY_REPORT_DIR:-$PROJECT_DIR/reports}"
BACKUP_ROOT="${CLASH_ENTRY_BACKUP_DIR:-$APP_DIR/entry-ip-backups}"
LATEST_REPORT="$STATE_DIR/latest-report.tsv"
CURRENT_BACKUP="$BACKUP_ROOT/current"
REPORT_TTL="${CLASH_ENTRY_REPORT_TTL:-1800}"
TEST_ROUNDS="${CLASH_ENTRY_TEST_ROUNDS:-5}"
SAMPLE_PORT_COUNT="${CLASH_ENTRY_SAMPLE_PORTS:-12}"
CONNECT_TIMEOUT="${CLASH_ENTRY_CONNECT_TIMEOUT:-3}"
MAX_CONCURRENCY="${CLASH_ENTRY_MAX_CONCURRENCY:-8}"
MANAGED_BEGIN='// CLASH_ENTRY_IP_MANAGED_BEGIN'
TAB=$(printf '\t')

log(){ printf '%s\n' "$*"; }
die(){ printf '错误：%s\n' "$*" >&2; exit 1; }
need(){ command -v "$1" >/dev/null 2>&1 || die "缺少命令：$1"; }
check_files(){ [ -f "$RUNTIME_CONFIG" ]&&[ -f "$BASE_CONFIG" ]&&[ -f "$PROFILES_CONFIG" ] || die 'Clash Verge配置文件不完整'; }
safe_dirs(){ mkdir -p "$STATE_DIR" "$REPORT_DIR"; chmod 700 "$STATE_DIR" "$REPORT_DIR" 2>/dev/null||true; }
is_ipv4(){ awk -F. 'NF!=4{exit 1}{for(i=1;i<=4;i++)if($i!~/^[0-9]+$/||$i>255)exit 1}' <<EOF
$1
EOF
}
fingerprint(){ shasum -a 256 "$1"|awk '{print $1}'; }
scalar(){ sed -n "s/^[[:space:]]*$1:[[:space:]]*//p" "$2"|head -1|sed -E "s/^['\"]//;s/['\"]$//"; }

# uid、名称、原始文件、脚本文件
current_profile(){ ruby --disable-gems -ryaml -e '
d=YAML.load_file(ARGV[0])||{}; a=d["items"]||d["profiles"]||d; a=a.values if a.is_a?(Hash); a=Array(a)
p=a.find{|x|x.is_a?(Hash)&&x["uid"]==d["current"]&&x["type"]=="remote"};abort "current profile missing" unless p&&p["file"]
s=a.find{|x|x.is_a?(Hash)&&x["uid"]==(p["option"]||{})["script"]&&x["type"]=="script"};abort "script missing" unless s&&s["file"]
v=[p["uid"],p["name"].to_s,p["file"],s["file"]];abort "invalid metadata" if v.any?{|x|x.to_s=~/[\t\r\n]/};puts v.join("\t")' "$PROFILES_CONFIG"; }

# 容错提取 proxies；兼容块状及 {name: ..., server: ..., port: ...}。
extract_nodes(){ ruby --disable-gems -e '
def c(v);v.to_s.strip.sub(/\A"/,"").sub(/"\z/,"").sub(/\A\x27/,"").sub(/\x27\z/,"");end
def out(n,s,p);return if s.to_s.empty?||!(p.to_s =~ /\A\s*\d+\s*\z/);v=[n,s,p].map{|x|c(x).gsub(/[\t\r\n]/," ")};info=!!(v[0]=~/(官网地址|剩余流量|流量剩余|套餐时间|到期时间|订阅到期)/);puts((v+[info ? "yes":"no"]).join("\t"));end
inside=false;n=s=p=nil
File.foreach(ARGV[0]) do|l|
 if !inside;inside=true if l=~/^proxies:\s*$/;next;end
 break if l=~/^[^\s#-][^:]*:/
 if l=~/^\s*-\s*\{(.*)\}\s*$/;b=$1;out(b[/\bname:\s*(.*?)(?=,\s*[\w-]+:)/,1],b[/\bserver:\s*([^,}]+)/,1],b[/\bport:\s*([^,}]+)/,1]);n=s=p=nil;next;end
 if l=~/^\s*-\s*name:\s*(.*)$/;out(n,s,p);n=$1;s=p=nil;next;end
 s=$1 if l=~/^\s+server:\s*(.*?)\s*$/;p=$1 if l=~/^\s+port:\s*(.*?)\s*$/
end;out(n,s,p)' "$1"; }

classify(){
 awk -F '\t' '$4!="yes"&&$2!=""&&$3~/^[0-9]+$/{print}' "$1">"$2.real"
 [ -s "$2.real" ]||{ printf 'empty\t-\n'>"$2";return; }
 awk -F '\t' 'function ip(s,a,i){if(split(s,a,".")!=4)return 0;for(i=1;i<=4;i++)if(a[i]!~/^[0-9]+$/||a[i]>255)return 0;return 1}{if(ip($2))x[$2]++;else h[tolower($2)]++}END{for(v in h)print "host\t"v"\t"h[v];for(v in x)print "ip\t"v"\t"x[v]}' "$2.real"|sort>"$2.entries"
 local h i;h=$(awk -F '\t' '$1=="host"{n++}END{print n+0}' "$2.entries");i=$(awk -F '\t' '$1=="ip"{n++}END{print n+0}' "$2.entries")
 if [ "$h" -gt 0 ]&&[ "$i" -gt 0 ];then printf 'mixed\t-\n'>"$2";elif [ "$i" -eq 1 ];then awk -F '\t' '$1=="ip"{print "single_ip\t"$2}' "$2.entries">"$2";elif [ "$i" -gt 1 ];then printf 'multiple_ips\t-\n'>"$2";elif [ "$h" -eq 1 ];then awk -F '\t' '$1=="host"{print "single_domain\t"$2}' "$2.entries">"$2";else printf 'multiple_domains\t-\n'>"$2";fi
}

nameservers(){ ruby --disable-gems -ryaml -e 'begin;d=YAML.load_file(ARGV[0])||{};x=d["dns"]||{};(Array(x["nameserver"])+Array(x["default-nameserver"])+Array(x["proxy-server-nameserver"])).each{|v|puts v if v.to_s=~/\A(?:\d{1,3}\.){3}\d{1,3}\z/};rescue StandardError;end' "$RUNTIME_CONFIG"|sort -u; }
discover(){
 local domain=$1 output=$2 root;:>"$output"
 add(){ local src=$1;shift;"$@" 2>/dev/null|awk -v s="$src" '{for(i=1;i<=NF;i++)if($i~/^([0-9]{1,3}\.){3}[0-9]{1,3}$/)print $i"\t"s}'>>"$output"||true; }
 add system dig +short A "$domain";command -v dscacheutil>/dev/null&&add cache dscacheutil -q host -a name "$domain"
 nameservers|while read -r ns;do [ -n "$ns" ]&&add "resolver:$ns" dig "@$ns" +short A "$domain";done
 root=$(awk -F. '{print $(NF-1)"."$NF}'<<<"$domain");dig +short NS "$root" 2>/dev/null|sed 's/\.$//'|while read -r ns;do [ -n "$ns" ]&&add "authority:$ns" dig "@$ns" +short A "$domain";done
 awk -F '\t' 'function ok(s,a,i){if(split(s,a,".")!=4)return 0;for(i=1;i<=4;i++)if(a[i]!~/^[0-9]+$/||a[i]>255)return 0;return 1}ok($1){if(!z[$1,$2]++)v[$1]=v[$1](v[$1]?",":"")$2}END{for(i in v)print i"\t"v[i]}' "$output"|sort -t. -k1,1n -k2,2n -k3,3n -k4,4n>"$output.tmp";mv "$output.tmp" "$output"
}

select_ports(){ awk -v w="$SAMPLE_PORT_COUNT" '{a[++n]=$1;if($1==9051)f=n}END{if(n<=w){for(i=1;i<=n;i++)print a[i];exit}for(i=0;i<w;i++)s[1+int(i*(n-1)/(w-1))]=1;if(f&&!s[f]){s[f]=1;for(i=n;i>=1;i--)if(s[i]&&i!=f){delete s[i];break}}for(i=1;i<=n;i++)if(s[i])print a[i]}' "$1">"$2"; }
probe(){ local st en ok ms;st=$(perl -MTime::HiRes=time -e 'printf "%.6f",time');if nc -G "$CONNECT_TIMEOUT" -vz "$1" "$2">/dev/null 2>&1;then ok=1;else ok=0;fi;en=$(perl -MTime::HiRes=time -e 'printf "%.6f",time');ms=$(awk -v a="$st" -v b="$en" 'BEGIN{printf "%.3f",(b-a)*1000}');printf '%s\t%s\t%s\t%s\n' "$1" "$2" "$ok" "$ms"; }
run_tasks(){ :>"$2";export CLASH_ENTRY_CONNECT_TIMEOUT="$CONNECT_TIMEOUT" CLASH_ENTRY_RESULTS_FILE="$2";xargs -P "$MAX_CONCURRENCY" -n 2 "$0" __probe<"$1"; }

header(){ cat >"$1" <<EOF
# generated_epoch	$(date +%s)
# generated_at	$(date '+%Y-%m-%d %H:%M:%S %z')
# status	$2
# skip_reason	$3
# profile_uid	$4
# profile_name	$5
# raw_file	$6
# raw_fingerprint	$7
# domain	$8
# tested_ports	$9
# test_rounds	$TEST_ROUNDS
EOF
}
publish(){ cp "$1" "$LATEST_REPORT";chmod 600 "$1" "$LATEST_REPORT" 2>/dev/null||true; }
skip(){ header "$3" skipped "$1" "$4" "$5" "$6" "$7" "${8:--}" -;printf '# detail\t%s\n' "$2">>"$3";publish "$3";log "跳过：$2";log "报告：$3"; }

diagnose(){
 need ruby;need dig;need nc;need perl;need xargs;need shasum;check_files;safe_dirs
 local work meta uid name raw script rawpath hash nodes cls kind target report candidates count ports samples pcsv tasks results ip p r desc ipv6 recommended alternatives unavailable
 work=$(mktemp -d "${TMPDIR:-/tmp}/entry-diag.XXXXXX")||die '无法创建临时目录';trap 'rm -rf "${work:-}"' EXIT INT TERM
 meta=$(current_profile)||die '无法定位当前订阅';IFS="$TAB" read -r uid name raw script<<<"$meta";rawpath="$APP_DIR/profiles/$raw";[ -f "$rawpath" ]||die "找不到原始订阅：$rawpath";hash=$(fingerprint "$rawpath")
 nodes="$work/nodes";extract_nodes "$rawpath">"$nodes";cls="$work/class";classify "$nodes" "$cls";IFS="$TAB" read -r kind target<"$cls";report="$REPORT_DIR/diagnosis-$(date '+%Y%m%d-%H%M%S').tsv";log "当前订阅：${name:-$uid}（${uid}）"
 case "$kind" in
 empty)skip no_real_nodes '没有识别到可检测的真实代理节点' "$report" "$uid" "$name" "$raw" "$hash";return;;
 single_ip)skip fixed_ip "订阅已直接使用固定 IP ${target}，无需锁定" "$report" "$uid" "$name" "$raw" "$hash";return;;
 multiple_ips)desc=$(awk -F '\t' '$1=="ip"{printf "%s%s（%s个节点）",s,$2,$3;s=", "}' "$cls.entries");skip multiple_ips "原始订阅包含多个独立 IP：${desc}；不能安全替换为单一入口" "$report" "$uid" "$name" "$raw" "$hash";return;;
 mixed)skip mixed_endpoints '订阅同时包含域名和字面量 IP，无法确认统一入口' "$report" "$uid" "$name" "$raw" "$hash";return;;
 multiple_domains)desc=$(awk -F '\t' '$1=="host"{printf "%s%s（%s个节点）",s,$2,$3;s=", "}' "$cls.entries");skip multiple_domains "订阅包含多个真实入口域名：${desc}；不能统一锁定" "$report" "$uid" "$name" "$raw" "$hash";return;;esac
 candidates="$work/candidates";log "正在发现 $target 的入口 IPv4…";discover "$target" "$candidates";count=$(wc -l<"$candidates"|tr -d ' ')
 if [ "$count" -eq 0 ];then ipv6=$(dig +short AAAA "$target" 2>/dev/null|head -1);if [ -n "$ipv6" ];then skip ipv6_only "$target 仅发现 IPv6入口，当前脚本暂不支持" "$report" "$uid" "$name" "$raw" "$hash" "$target";else skip no_ipv4 "$target 没有解析到有效 IPv4" "$report" "$uid" "$name" "$raw" "$hash" "$target";fi;return;fi
 if [ "$count" -eq 1 ];then ip=$(awk -F '\t' 'NR==1{print $1}' "$candidates");skip single_dns_ip "$target 只解析到一个 IPv4：${ip}，没有多 IP漂移风险" "$report" "$uid" "$name" "$raw" "$hash" "$target";return;fi
 ports="$work/ports";awk -F '\t' -v d="$target" '$4!="yes"&&tolower($2)==d{print $3}' "$nodes"|sort -nu>"$ports";samples="$work/samples";select_ports "$ports" "$samples";pcsv=$(paste -sd, "$samples")
 log '候选入口：';awk -F '\t' '{printf "  %s（%s）\n",$1,$2}' "$candidates";log "测试端口：${pcsv}；每个 IP × 端口测试 ${TEST_ROUNDS}次"
 tasks="$work/tasks";:>"$tasks";while IFS="$TAB" read -r ip _;do while read -r p;do r=1;while [ "$r" -le "$TEST_ROUNDS" ];do printf '%s %s\n' "$ip" "$p">>"$tasks";r=$((r+1));done;done<"$samples";done<"$candidates";results="$work/results";run_tasks "$tasks" "$results"
 header "$report" testable - "$uid" "$name" "$raw" "$hash" "$target" "$pcsv";printf 'ip\teligible\tsuccess\ttotal\tsuccess_rate\taverage_ms\tfailed_ports\tsources\n'>>"$report"
 awk -F '\t' 'FNR==NR{s[$1]=$2;ip[++n]=$1;next}{t[$1]++;o[$1]+=$3;d[$1]+=$4;if(!$3)f[$1,$2]=1}END{for(i=1;i<=n;i++){x=ip[i];q="";for(k in f){split(k,p,SUBSEP);if(p[1]==x)q=q (q?",":"") p[2]}printf "%s\t%s\t%d\t%d\t%.1f%%\t%.3f\t%s\t%s\n",x,(o[x]==t[x]&&t[x]?"yes":"no"),o[x],t[x],t[x]?100*o[x]/t[x]:0,t[x]?d[x]/t[x]:0,q?q:"-",s[x]}}' "$candidates" "$results"|sort -t "$TAB" -k2,2r -k6,6n>>"$report";publish "$report"
 log '检测完成：';awk -F '\t' '$1~/^([0-9]+\.){3}[0-9]+$/{printf "  %s  可用=%s  成功=%s/%s（%s） 平均=%sms  失败端口=%s\n",$1,$2,$3,$4,$5,$6,$7}' "$report"
 recommended=$(awk -F '\t' '$2=="yes"{print $1;exit}' "$report");if [ -n "$recommended" ];then log "推荐 IP：$recommended";alternatives=$(awk -F '\t' -v x="$recommended" '$2=="yes"&&$1!=x{printf "%s%s",s,$1;s=", "}' "$report");log "可用备选 IP：${alternatives:-无}";else log '推荐 IP：无（没有候选地址通过全部测试）';fi;unavailable=$(awk -F '\t' '$2=="no"{printf "%s%s",s,$1;s=", "}' "$report");log "不可用 IP：${unavailable:-无}";log "报告：$report"
}

rv(){ awk -F '\t' -v k="$1" '$1==k{print $2;exit}' "$LATEST_REPORT"; }
validate(){ local ip=$1 now age meta uid name raw script path;[ -f "$LATEST_REPORT" ]||die '没有检测报告，请先执行 diagnose';[ "$(rv '# status')" = testable ]||die "最近诊断已跳过，不能应用（原因：$(rv '# skip_reason')）";now=$(date +%s);age=$((now-$(rv '# generated_epoch')));[ "$age" -ge 0 ]&&[ "$age" -le "$REPORT_TTL" ]||die '检测报告已过期，请重新诊断';meta=$(current_profile);IFS="$TAB" read -r uid name raw script<<<"$meta";[ "$uid" = "$(rv '# profile_uid')" ]||die '当前订阅已切换，请重新诊断';path="$APP_DIR/profiles/$raw";[ "$(fingerprint "$path")" = "$(rv '# raw_fingerprint')" ]||die '当前订阅已更新，请重新诊断';awk -F '\t' -v x="$ip" '$1==x&&$2=="yes"{z=1}END{exit !z}' "$LATEST_REPORT"||die "$ip 未通过最近一次严格检测"; }
safe_script(){ grep -qF "$MANAGED_BEGIN" "$1"&&return 0;[ "$(sed '/^[[:space:]]*\/\//d' "$1"|tr -d '[:space:]')" = 'functionmain(config,profileName){returnconfig;}' ]; }
managed(){ sed -n "s/^[[:space:]]*const $1 = \"\([^\"]*\)\";.*/\1/p" "$2"|head -1; }
write_script(){ local tmp="$1.tmp.$$";cat >"$tmp" <<EOF
$MANAGED_BEGIN
// 由 clash-entry-ip.sh 管理；使用 rollback 恢复。
function main(config, profileName) {
  const domain = "$2";
  const pinnedIp = "$3";
  if (Array.isArray(config.proxies)) {
    for (const proxy of config.proxies) {
      if (proxy && proxy.server === domain) proxy.server = pinnedIp;
    }
  }
  return config;
}
// CLASH_ENTRY_IP_MANAGED_END
EOF
chmod --reference="$1" "$tmp" 2>/dev/null||chmod 600 "$tmp";mv "$tmp" "$1"; }
transform(){ awk -v d="$3" -v ip="$4" -v old="$5" '/^proxies:[[:space:]]*$/{p=1;print;next}/^proxy-groups:[[:space:]]*$/{p=0}p&&/^[[:space:]]+server:/{v=$0;sub(/^[[:space:]]+server:[[:space:]]*/,"",v);gsub(/"/,"",v);gsub(sprintf("%c",39),"",v);if(v==d||(old!=""&&v==old)){match($0,/^[[:space:]]+/);printf "%sserver: %s\n",substr($0,RSTART,RLENGTH),ip;n++;next}}{print}END{if(!n)exit 8}' "$1">"$2"||die "运行配置中没有可替换的 $3 节点"; }

tcp_req(){
 local data=${3:-}
 if [ -n "${CONTROLLER_SECRET:-}" ]&&[ "$CONTROLLER_SECRET" != set-your-secret ];then
  if [ -n "$data" ];then curl -sSf --connect-timeout 3 -H "Authorization: Bearer $CONTROLLER_SECRET" -H 'Content-Type: application/json' -X "$1" --data-binary "@$data" "$CONTROLLER_URL$2";else curl -sSf --connect-timeout 3 -H "Authorization: Bearer $CONTROLLER_SECRET" -X "$1" "$CONTROLLER_URL$2";fi
 else
  if [ -n "$data" ];then curl -sSf --connect-timeout 3 -H 'Content-Type: application/json' -X "$1" --data-binary "@$data" "$CONTROLLER_URL$2";else curl -sSf --connect-timeout 3 -X "$1" "$CONTROLLER_URL$2";fi
 fi
}
controller_init(){ CONTROLLER_KIND='';CONTROLLER_SOCKET=$(scalar external-controller-unix "$RUNTIME_CONFIG");[ -n "$CONTROLLER_SOCKET" ]||CONTROLLER_SOCKET=$(scalar external-controller-unix "$BASE_CONFIG");if [ -n "$CONTROLLER_SOCKET" ]&&curl -sf --connect-timeout 2 --unix-socket "$CONTROLLER_SOCKET" http://localhost/version>/dev/null;then CONTROLLER_KIND=unix;return;fi;CONTROLLER_URL=$(scalar external-controller "$RUNTIME_CONFIG");[ -n "$CONTROLLER_URL" ]||CONTROLLER_URL=$(scalar external-controller "$BASE_CONFIG");case "$CONTROLLER_URL" in http*) ;; '')return 1;; *)CONTROLLER_URL="http://$CONTROLLER_URL";;esac;CONTROLLER_SECRET=$(scalar secret "$RUNTIME_CONFIG");[ -n "$CONTROLLER_SECRET" ]||CONTROLLER_SECRET=$(scalar secret "$BASE_CONFIG");tcp_req GET /version>/dev/null 2>&1&&{ CONTROLLER_KIND=tcp;return;};return 1; }
request(){ if [ "$CONTROLLER_KIND" = unix ];then if [ -n "${3:-}" ];then curl -sSf --connect-timeout 3 --unix-socket "$CONTROLLER_SOCKET" -H 'Content-Type: application/json' -X "$1" --data-binary "@$3" "http://localhost$2";else curl -sSf --connect-timeout 3 --unix-socket "$CONTROLLER_SOCKET" -X "$1" "http://localhost$2";fi;else tcp_req "$@";fi; }
reload(){ ruby --disable-gems -rjson -e 'print JSON.generate({"payload"=>File.read(ARGV[0])})' "$1">"$2";request PUT '/configs?force=true' "$2">/dev/null&&request GET /configs>/dev/null; }
smoke(){ local port code;port=$(scalar mixed-port "$RUNTIME_CONFIG");[ -n "$port" ]||port=7897;code=$(curl --silent --output /dev/null --write-out '%{http_code}' --connect-timeout 8 --max-time 15 --proxy "http://127.0.0.1:$port" https://www.google.com/generate_204||true);case "$code" in 2*|3*)return;;*)return 1;;esac; }
restore(){ local t="$2.restore.$$";cp "$1" "$t";chmod --reference="$2" "$t" 2>/dev/null||true;mv "$t" "$2"; }

apply_ip(){
 local ip=${1:-} meta uid name raw script sp domain old oldd stamp backup manifest work changed payload fail=0
 [ -n "$ip" ]||die "用法：$0 apply <IPv4>";is_ipv4 "$ip"||die "非法 IPv4：$ip";validate "$ip";need curl;check_files;controller_init||die 'Mihomo控制接口不可连接；未修改配置'
 meta=$(current_profile);IFS="$TAB" read -r uid name raw script<<<"$meta";sp="$APP_DIR/profiles/$script";[ -f "$sp" ]||die '脚本覆写不存在';safe_script "$sp"||die '当前订阅脚本已有自定义逻辑，拒绝覆盖';domain=$(rv '# domain');old=$(managed pinnedIp "$sp");oldd=$(managed domain "$sp");[ "$old" = "$ip" ]&&[ "$oldd" = "$domain" ]&&{ log "已经锁定 $domain -> ${ip}，无需重复写入";return; }
 stamp=$(date '+%Y%m%d-%H%M%S');backup="$BACKUP_ROOT/$stamp";mkdir -p "$backup";chmod 700 "$BACKUP_ROOT" "$backup" 2>/dev/null||true;cp "$sp" "$backup/script.js";cp "$RUNTIME_CONFIG" "$backup/clash-verge.yaml";manifest="$backup/manifest.tsv";printf 'script\t%s\tscript.js\nruntime\t%s\tclash-verge.yaml\n' "$sp" "$RUNTIME_CONFIG">"$manifest"
 work=$(mktemp -d "${TMPDIR:-/tmp}/entry-apply.XXXXXX");changed="$work/config";payload="$work/payload";transform "$RUNTIME_CONFIG" "$changed" "$domain" "$ip" "$old";write_script "$sp" "$domain" "$ip"||fail=1;[ "$fail" -ne 0 ]||restore "$changed" "$RUNTIME_CONFIG"||fail=1;[ "$fail" -ne 0 ]||reload "$RUNTIME_CONFIG" "$payload"||fail=1;[ "$fail" -ne 0 ]||smoke||fail=1
 if [ "$fail" -ne 0 ];then restore "$backup/script.js" "$sp"||true;restore "$backup/clash-verge.yaml" "$RUNTIME_CONFIG"||true;reload "$RUNTIME_CONFIG" "$payload">/dev/null 2>&1||true;rm -rf "$work";die '应用失败，文件已恢复';fi
 printf '%s\n' "$backup">"$CURRENT_BACKUP";chmod 600 "$CURRENT_BACKUP" 2>/dev/null||true;rm -rf "$work";log "已锁定当前订阅：$domain -> $ip";log 'Mihomo已重载，本地代理验证通过。';log "备份：$backup"
}
status(){
 check_files
 local meta uid name raw script sp ip d
 meta=$(current_profile)||die '无法定位当前订阅';IFS="$TAB" read -r uid name raw script<<<"$meta"
 sp="$APP_DIR/profiles/$script";ip=$(managed pinnedIp "$sp");d=$(managed domain "$sp")
 log "当前订阅：${name:-$uid}（${uid}）";log "原始配置：$raw"
 if [ -n "$ip" ];then log "入口锁定：$d -> $ip";else log '入口锁定：未锁定';fi
 if controller_init;then log "Mihomo控制接口：可用（${CONTROLLER_KIND}）";else log 'Mihomo控制接口：不可用';fi
 if [ -f "$LATEST_REPORT" ];then log "最近报告：$(rv '# status')，订阅=$(rv '# profile_name')，域名=$(rv '# domain')，原因=$(rv '# skip_reason')";else log '最近报告：无';fi
 return 0
}
rollback(){ need curl;[ -f "$CURRENT_BACKUP" ]||die '没有可回滚的成功应用';local b m k d f w;b=$(cat "$CURRENT_BACKUP");m="$b/manifest.tsv";[ -f "$m" ]||die '备份清单不存在';controller_init||die 'Mihomo控制接口不可连接；未修改配置';while IFS="$TAB" read -r k d f;do case "$k" in script|runtime)restore "$b/$f" "$d"||die "恢复失败：$d";;esac;done<"$m";w=$(mktemp -d "${TMPDIR:-/tmp}/entry-rollback.XXXXXX");reload "$RUNTIME_CONFIG" "$w/payload"||die '文件已恢复，但 Mihomo重载失败';rm -rf "$w";mv "$CURRENT_BACKUP" "$b/rolled-back-at-$(date '+%Y%m%d-%H%M%S')";log "已恢复：$b"; }
usage(){ printf '用法：\n  %s diagnose\n  %s apply <IPv4>\n  %s status\n  %s rollback\n' "$0" "$0" "$0" "$0"; }
case "${1:-}" in diagnose)diagnose;;apply)apply_ip "${2:-}";;status)status;;rollback)rollback;;__probe)CONNECT_TIMEOUT="${CLASH_ENTRY_CONNECT_TIMEOUT:-3}";probe "${2:-}" "${3:-}">>"${CLASH_ENTRY_RESULTS_FILE:?}";;help|-h|--help|'')usage;;*)usage>&2;exit 1;;esac
