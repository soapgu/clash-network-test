#!/usr/bin/env bash
set -u

PROJECT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
STATE_DIR="${CFA_ENTRY_STATE_DIR:-$PROJECT_DIR/.state}"
REPORT_DIR="${CFA_ENTRY_REPORT_DIR:-$PROJECT_DIR/reports}"
OUTPUT_DIR="${CFA_ENTRY_OUTPUT_DIR:-$PROJECT_DIR/outputs}"
LATEST_REPORT="$STATE_DIR/cfa-latest-report.tsv"
LATEST_OUTPUT="$STATE_DIR/cfa-latest-output.tsv"
REPORT_TTL="${CFA_ENTRY_REPORT_TTL:-1800}"
TEST_ROUNDS="${CFA_ENTRY_TEST_ROUNDS:-5}"
SAMPLE_PORT_COUNT="${CFA_ENTRY_SAMPLE_PORTS:-12}"
CONNECT_TIMEOUT="${CFA_ENTRY_CONNECT_TIMEOUT:-3}"
MAX_CONCURRENCY="${CFA_ENTRY_MAX_CONCURRENCY:-8}"
TAB=$(printf '\t')

log(){ printf '%s\n' "$*"; }
die(){ printf '错误：%s\n' "$*" >&2; exit 1; }
need(){ command -v "$1" >/dev/null 2>&1 || die "缺少命令：$1"; }
safe_dirs(){ mkdir -p "$STATE_DIR" "$REPORT_DIR" "$OUTPUT_DIR";chmod 700 "$STATE_DIR" "$REPORT_DIR" "$OUTPUT_DIR" 2>/dev/null||true; }
is_ipv4(){ awk -F. 'NF!=4{exit 1}{for(i=1;i<=4;i++)if($i!~/^[0-9]+$/||$i>255)exit 1}' <<EOF
$1
EOF
}
fingerprint(){ shasum -a 256 "$1"|awk '{print $1}'; }
absolute_path(){ local d b;d=$(dirname -- "$1");b=$(basename -- "$1");d=$(CDPATH= cd -- "$d" 2>/dev/null&&pwd)||return 1;printf '%s/%s\n' "$d" "$b"; }
check_input(){
 local p=$1
 [ -f "$p" ]||die "找不到 CFA 导出配置：$p"
 case "$(basename -- "$p")" in *.yaml|*.yml|*.yaml.txt|*.yml.txt) ;;*)die '输入文件必须是 .yaml、.yml、.yaml.txt 或 .yml.txt';;esac
 [ -r "$p" ]||die "无法读取 CFA 导出配置：$p"
}

# 容错提取 proxies，兼容 CFA 常见的块状和行内宽松 YAML。
extract_nodes(){ ruby --disable-gems -e '
def c(v);v.to_s.strip.sub(/\A"/,"").sub(/"\z/,"").sub(/\A\x27/,"").sub(/\x27\z/,"");end
def out(n,s,p,t);return if s.to_s.empty?||!(p.to_s =~ /\A\s*\d+\s*\z/);v=[n,s,p,t].map{|x|c(x).gsub(/[\t\r\n]/," ")};info=!!(v[0]=~/(官网地址|剩余流量|流量剩余|套餐时间|到期时间|订阅到期)/);puts((v+[info ? "yes":"no"]).join("\t"));end
inside=false;n=s=p=t=nil
File.foreach(ARGV[0]) do|l|
 if !inside;inside=true if l=~/^proxies:\s*$/;next;end
 break if l=~/^[^\s#-][^:]*:/
 if l=~/^\s*-\s*\{(.*)\}\s*$/;b=$1;out(b[/\bname:\s*(.*?)(?=,\s*[\w-]+:)/,1],b[/\bserver:\s*([^,}]+)/,1],b[/\bport:\s*([^,}]+)/,1],b[/\btype:\s*([^,}]+)/,1]);n=s=p=t=nil;next;end
 if l=~/^\s*-\s*name:\s*(.*)$/;out(n,s,p,t);n=$1;s=p=t=nil;next;end
 s=$1 if l=~/^\s+server:\s*(.*?)\s*$/;p=$1 if l=~/^\s+port:\s*(.*?)\s*$/;t=$1 if l=~/^\s+type:\s*(.*?)\s*$/
end;out(n,s,p,t)' "$1"; }

classify(){
 awk -F '\t' '$5!="yes"&&$2!=""&&$3~/^[0-9]+$/{print}' "$1">"$2.real"
 [ -s "$2.real" ]||{ printf 'empty\t-\n'>"$2";return; }
 awk -F '\t' 'function ip(s,a,i){if(split(s,a,".")!=4)return 0;for(i=1;i<=4;i++)if(a[i]!~/^[0-9]+$/||a[i]>255)return 0;return 1}{if(ip($2))x[$2]++;else h[tolower($2)]++}END{for(v in h)print "host\t"v"\t"h[v];for(v in x)print "ip\t"v"\t"x[v]}' "$2.real"|sort>"$2.entries"
 local h i;h=$(awk -F '\t' '$1=="host"{n++}END{print n+0}' "$2.entries");i=$(awk -F '\t' '$1=="ip"{n++}END{print n+0}' "$2.entries")
 if [ "$h" -gt 0 ]&&[ "$i" -gt 0 ];then printf 'mixed\t-\n'>"$2";elif [ "$i" -eq 1 ];then awk -F '\t' '$1=="ip"{print "single_ip\t"$2}' "$2.entries">"$2";elif [ "$i" -gt 1 ];then printf 'multiple_ips\t-\n'>"$2";elif [ "$h" -eq 1 ];then awk -F '\t' '$1=="host"{print "single_domain\t"$2}' "$2.entries">"$2";else printf 'multiple_domains\t-\n'>"$2";fi
}

# 从导出配置的 dns 段提取字面量 IPv4；宽松解析避免整份 YAML 的格式问题。
nameservers(){ awk '
/^dns:[[:space:]]*$/{d=1;next}d&&/^[^[:space:]#]/{exit}d{for(i=1;i<=NF;i++){v=$i;gsub(/^["'\''\[, -]+|["'\''\],]+$/,"",v);if(v~/^([0-9]{1,3}\.){3}[0-9]{1,3}$/)print v}}' "$1"|sort -u; }
discover(){
 local domain=$1 input=$2 output=$3 root;:>"$output"
 add(){ local src=$1;shift;"$@" 2>/dev/null|awk -v s="$src" '{for(i=1;i<=NF;i++)if($i~/^([0-9]{1,3}\.){3}[0-9]{1,3}$/)print $i"\t"s}'>>"$output"||true; }
 add system dig +short A "$domain";command -v dscacheutil>/dev/null&&add cache dscacheutil -q host -a name "$domain"
 nameservers "$input"|while read -r ns;do [ -n "$ns" ]&&add "config-resolver:$ns" dig "@$ns" +short A "$domain";done
 root=$(awk -F. '{print $(NF-1)"."$NF}'<<<"$domain");dig +short NS "$root" 2>/dev/null|sed 's/\.$//'|while read -r ns;do [ -n "$ns" ]&&add "authority:$ns" dig "@$ns" +short A "$domain";done
 awk -F '\t' 'function ok(s,a,i){if(split(s,a,".")!=4)return 0;for(i=1;i<=4;i++)if(a[i]!~/^[0-9]+$/||a[i]>255)return 0;return 1}ok($1){if(!z[$1,$2]++)v[$1]=v[$1](v[$1]?",":"")$2}END{for(i in v)print i"\t"v[i]}' "$output"|sort -t. -k1,1n -k2,2n -k3,3n -k4,4n>"$output.tmp";mv "$output.tmp" "$output"
}

select_ports(){ awk -v w="$SAMPLE_PORT_COUNT" '{a[++n]=$1;if($1==9051)f=n}END{if(n<=w){for(i=1;i<=n;i++)print a[i];exit}for(i=0;i<w;i++)s[1+int(i*(n-1)/(w-1))]=1;if(f&&!s[f]){s[f]=1;for(i=n;i>=1;i--)if(s[i]&&i!=f){delete s[i];break}}for(i=1;i<=n;i++)if(s[i])print a[i]}' "$1">"$2"; }
probe(){ local st en ok ms;st=$(perl -MTime::HiRes=time -e 'printf "%.6f",time');if nc -G "$CONNECT_TIMEOUT" -vz "$1" "$2">/dev/null 2>&1;then ok=1;else ok=0;fi;en=$(perl -MTime::HiRes=time -e 'printf "%.6f",time');ms=$(awk -v a="$st" -v b="$en" 'BEGIN{printf "%.3f",(b-a)*1000}');printf '%s\t%s\t%s\t%s\n' "$1" "$2" "$ok" "$ms"; }
run_tasks(){ :>"$2";export CFA_ENTRY_CONNECT_TIMEOUT="$CONNECT_TIMEOUT" CFA_ENTRY_RESULTS_FILE="$2";xargs -P "$MAX_CONCURRENCY" -n 2 "$0" __probe<"$1"; }

header(){ printf '# generated_epoch\t%s\n# generated_at\t%s\n# status\t%s\n# skip_reason\t%s\n# source_path\t%s\n# source_name\t%s\n# source_fingerprint\t%s\n# domain\t%s\n# real_nodes\t%s\n# replacement_nodes\t%s\n# tested_ports\t%s\n# test_rounds\t%s\n' \
 "$(date +%s)" "$(date '+%Y-%m-%d %H:%M:%S %z')" "$2" "$3" "$4" "$5" "$6" "$7" "$8" "$9" "${10}" "$TEST_ROUNDS">"$1"; }
publish(){ cp "$1" "$LATEST_REPORT";chmod 600 "$1" "$LATEST_REPORT" 2>/dev/null||true; }
skip(){ header "$3" skipped "$1" "$4" "$5" "$6" "${7:--}" "${8:-0}" "${9:-0}" -;printf '# detail\t%s\n' "$2">>"$3";publish "$3";log "跳过：$2";log "报告：$3"; }

diagnose(){
 local given=${1:-} input hash work nodes cls kind target report desc candidates count ipv6 realn replacen ports samples pcsv tasks results ip r recommended alternatives unavailable
 [ -n "$given" ]||die "用法：$0 diagnose <CFA导出的yaml>";check_input "$given";need ruby;need dig;need nc;need perl;need xargs;need shasum;safe_dirs
 input=$(absolute_path "$given")||die "无法解析输入路径：$given";hash=$(fingerprint "$input");work=$(mktemp -d "${TMPDIR:-/tmp}/cfa-entry-diag.XXXXXX")||die '无法创建临时目录';trap 'rm -rf "${work:-}"' EXIT INT TERM
 nodes="$work/nodes";extract_nodes "$input">"$nodes";cls="$work/class";classify "$nodes" "$cls";IFS="$TAB" read -r kind target<"$cls";report="$REPORT_DIR/cfa-diagnosis-$(date '+%Y%m%d-%H%M%S').tsv";log "CFA 导出配置：$input"
 case "$kind" in
 empty)skip no_real_nodes '没有识别到可检测的真实代理节点' "$report" "$input" "$(basename -- "$input")" "$hash";return;;
 single_ip)skip fixed_ip "配置已直接使用固定 IP ${target}，无需锁定" "$report" "$input" "$(basename -- "$input")" "$hash";return;;
 multiple_ips)desc=$(awk -F '\t' '$1=="ip"{printf "%s%s（%s个节点）",s,$2,$3;s=", "}' "$cls.entries");skip multiple_ips "配置包含多个独立 IP：${desc}；不能安全替换为单一入口" "$report" "$input" "$(basename -- "$input")" "$hash";return;;
 mixed)skip mixed_endpoints '配置同时包含域名和字面量 IP，无法确认统一入口' "$report" "$input" "$(basename -- "$input")" "$hash";return;;
 multiple_domains)desc=$(awk -F '\t' '$1=="host"{printf "%s%s（%s个节点）",s,$2,$3;s=", "}' "$cls.entries");skip multiple_domains "配置包含多个真实入口域名：${desc}；不能统一锁定" "$report" "$input" "$(basename -- "$input")" "$hash";return;;esac
 realn=$(awk -F '\t' -v d="$target" 'tolower($2)==d{n++}END{print n+0}' "$cls.real");replacen=$(awk -F '\t' -v d="$target" 'tolower($2)==d{n++}END{print n+0}' "$nodes")
 candidates="$work/candidates";log "正在发现 $target 的入口 IPv4…";discover "$target" "$input" "$candidates";count=$(wc -l<"$candidates"|tr -d ' ')
 if [ "$count" -eq 0 ];then ipv6=$(dig +short AAAA "$target" 2>/dev/null|head -1);if [ -n "$ipv6" ];then skip ipv6_only "$target 仅发现 IPv6 入口，当前脚本暂不支持" "$report" "$input" "$(basename -- "$input")" "$hash" "$target" "$realn" "$replacen";else skip no_ipv4 "$target 没有解析到有效 IPv4" "$report" "$input" "$(basename -- "$input")" "$hash" "$target" "$realn" "$replacen";fi;return;fi
 if [ "$count" -eq 1 ];then ip=$(awk -F '\t' 'NR==1{print $1}' "$candidates");skip single_dns_ip "$target 只解析到一个 IPv4：${ip}，没有多 IP 漂移风险" "$report" "$input" "$(basename -- "$input")" "$hash" "$target" "$realn" "$replacen";return;fi
 ports="$work/ports";awk -F '\t' -v d="$target" '$5!="yes"&&tolower($2)==d{print $3}' "$nodes"|sort -nu>"$ports";samples="$work/samples";select_ports "$ports" "$samples";pcsv=$(paste -sd, "$samples")
 log '候选入口：';awk -F '\t' '{printf "  %s（%s）\n",$1,$2}' "$candidates";log "测试端口：${pcsv}；每个 IP × 端口测试 ${TEST_ROUNDS} 次"
 tasks="$work/tasks";:>"$tasks";while IFS="$TAB" read -r ip _;do while read -r p;do r=1;while [ "$r" -le "$TEST_ROUNDS" ];do printf '%s %s\n' "$ip" "$p">>"$tasks";r=$((r+1));done;done<"$samples";done<"$candidates";results="$work/results";run_tasks "$tasks" "$results"
 header "$report" testable - "$input" "$(basename -- "$input")" "$hash" "$target" "$realn" "$replacen" "$pcsv";printf 'ip\teligible\tsuccess\ttotal\tsuccess_rate\taverage_ms\tfailed_ports\tsources\n'>>"$report"
 awk -F '\t' 'FNR==NR{s[$1]=$2;ip[++n]=$1;next}{t[$1]++;o[$1]+=$3;d[$1]+=$4;if(!$3)f[$1,$2]=1}END{for(i=1;i<=n;i++){x=ip[i];q="";for(k in f){split(k,p,SUBSEP);if(p[1]==x)q=q (q?",":"") p[2]}printf "%s\t%s\t%d\t%d\t%.1f%%\t%.3f\t%s\t%s\n",x,(o[x]==t[x]&&t[x]?"yes":"no"),o[x],t[x],t[x]?100*o[x]/t[x]:0,t[x]?d[x]/t[x]:0,q?q:"-",s[x]}}' "$candidates" "$results"|sort -t "$TAB" -k2,2r -k6,6n>>"$report";publish "$report"
 log '检测完成：';awk -F '\t' '$1~/^([0-9]+\.){3}[0-9]+$/{printf "  %s  可用=%s  成功=%s/%s（%s） 平均=%sms  失败端口=%s\n",$1,$2,$3,$4,$5,$6,$7}' "$report"
 recommended=$(awk -F '\t' '$2=="yes"{print $1;exit}' "$report");if [ -n "$recommended" ];then log "推荐 IP：$recommended";alternatives=$(awk -F '\t' -v x="$recommended" '$2=="yes"&&$1!=x{printf "%s%s",s,$1;s=", "}' "$report");log "可用备选 IP：${alternatives:-无}";else log '推荐 IP：无（没有候选地址通过全部测试）';fi;unavailable=$(awk -F '\t' '$2=="no"{printf "%s%s",s,$1;s=", "}' "$report");log "不可用 IP：${unavailable:-无}";log "报告：$report"
}

rv(){ awk -F '\t' -v k="$1" '$1==k{print $2;exit}' "$LATEST_REPORT"; }
validate_apply(){
 local ip=$1 source now age
 [ -f "$LATEST_REPORT" ]||die '没有 CFA 检测报告，请先执行 diagnose'
 [ "$(rv '# status')" = testable ]||die "最近诊断已跳过，不能应用（原因：$(rv '# skip_reason')）"
 now=$(date +%s);age=$((now-$(rv '# generated_epoch')));[ "$age" -ge 0 ]&&[ "$age" -le "$REPORT_TTL" ]||die '检测报告已过期，请重新诊断'
 source=$(rv '# source_path');[ -f "$source" ]||die "诊断使用的源文件已不存在：$source"
 [ "$(fingerprint "$source")" = "$(rv '# source_fingerprint')" ]||die '源文件已被修改，请重新诊断'
 awk -F '\t' -v x="$ip" '$1==x&&$2=="yes"{z=1}END{exit !z}' "$LATEST_REPORT"||die "$ip 未通过最近一次严格检测"
}

transform(){ ruby --disable-gems -e '
domain=ARGV[2].downcase;ip=ARGV[3];inside=false;count=0
File.open(ARGV[1],"wb",0600) do|o|
 File.foreach(ARGV[0]) do|line|
  if !inside
   inside=true if line=~/^proxies:\s*$/
  elsif line=~/^[^\s#-][^:]*:/
   inside=false
  end
  if inside
   line=line.gsub(/(\bserver:\s*)(?:"([^"]+)"|\x27([^\x27]+)\x27|([^,\s}\#]+))/) do
    value=$2||$3||$4
    if value.downcase==domain
     count+=1
     quote=$2 ? "\"" : ($3 ? "\x27" : "")
     "#{$1}#{quote}#{ip}#{quote}"
    else
     $&
    end
   end
  end
  o.write(line)
 end
end
puts count' "$1" "$2" "$3" "$4"; }

apply_ip(){
 local ip=${1:-} source domain expected base stamp output n=0 tmp changed nodes left locked
 [ -n "$ip" ]||die "用法：$0 apply <IPv4>";is_ipv4 "$ip"||die "非法 IPv4：$ip";need ruby;need shasum;validate_apply "$ip";safe_dirs
 source=$(rv '# source_path');domain=$(rv '# domain');expected=$(rv '# replacement_nodes');base=$(basename -- "$source");base=${base%.txt};base=${base%.yaml};base=${base%.yml};stamp=$(date '+%Y%m%d-%H%M%S');output="$OUTPUT_DIR/${base}-locked-${ip}-${stamp}.yaml"
 while [ -e "$output" ];do n=$((n+1));output="$OUTPUT_DIR/${base}-locked-${ip}-${stamp}-${n}.yaml";done
 tmp=$(mktemp "$OUTPUT_DIR/.cfa-locked.XXXXXX")||die '无法创建临时输出';chmod 600 "$tmp" 2>/dev/null||true
 changed=$(transform "$source" "$tmp" "$domain" "$ip")||{ rm -f "$tmp";die '生成锁定配置失败'; }
 [ "$changed" = "$expected" ]||{ rm -f "$tmp";die "替换数量不匹配：预期 ${expected}，实际 ${changed}"; }
 nodes=$(mktemp "${TMPDIR:-/tmp}/cfa-entry-check.XXXXXX")||{ rm -f "$tmp";die '无法创建校验文件';};extract_nodes "$tmp">"$nodes";left=$(awk -F '\t' -v d="$domain" 'tolower($2)==d{n++}END{print n+0}' "$nodes");locked=$(awk -F '\t' -v x="$ip" '$2==x{n++}END{print n+0}' "$nodes");rm -f "$nodes"
 [ "$left" -eq 0 ]&&[ "$locked" -ge "$expected" ]||{ rm -f "$tmp";die '输出校验失败，目标入口未全部锁定'; }
 mv "$tmp" "$output";chmod 600 "$output" 2>/dev/null||true
 printf 'generated_epoch\t%s\ngenerated_at\t%s\nsource_path\t%s\nsource_fingerprint\t%s\ndomain\t%s\nlocked_ip\t%s\noutput_path\t%s\n' "$(date +%s)" "$(date '+%Y-%m-%d %H:%M:%S %z')" "$source" "$(rv '# source_fingerprint')" "$domain" "$ip" "$output">"$LATEST_OUTPUT";chmod 600 "$LATEST_OUTPUT" 2>/dev/null||true
 log "已生成 CFA 锁定配置：$output";log "入口锁定：$domain -> $ip";log '原导出文件未修改；请将生成的 YAML 手动导入手机 CFA。'
}

ov(){ awk -F '\t' -v k="$1" '$1==k{print $2;exit}' "$LATEST_OUTPUT"; }
status(){
 local now age source valid eligible output
 log '说明：这里只显示电脑上的诊断和生成状态，无法判断手机 CFA 是否已经导入或启用。'
 if [ ! -f "$LATEST_REPORT" ];then log '最近诊断：无';else
  log "最近诊断：$(rv '# status')";log "跳过原因：$(rv '# skip_reason')";source=$(rv '# source_path');log "源文件：$source"
  if [ ! -f "$source" ];then log '源文件状态：不存在';elif [ "$(fingerprint "$source")" = "$(rv '# source_fingerprint')" ];then log '源文件状态：未变化';else log '源文件状态：内容已变化';fi
  now=$(date +%s);age=$((now-$(rv '# generated_epoch')));if [ "$age" -ge 0 ]&&[ "$age" -le "$REPORT_TTL" ];then valid=有效;else valid=已过期;fi;log "报告时效：$valid";log "入口域名：$(rv '# domain')";eligible=$(awk -F '\t' '$2=="yes"{printf "%s%s",s,$1;s=", "}' "$LATEST_REPORT");log "合格 IP：${eligible:-无}"
 fi
 if [ ! -f "$LATEST_OUTPUT" ];then log '最近生成：无';else output=$(ov output_path);log "最近生成：$output";log "锁定 IP：$(ov locked_ip)";log "生成时间：$(ov generated_at)";if [ -f "$output" ];then log '输出状态：存在';else log '输出状态：不存在';fi;fi
}

usage(){ printf '用法：\n  %s diagnose <CFA导出的yaml>\n  %s apply <IPv4>\n  %s status\n' "$0" "$0" "$0"; }
case "${1:-}" in diagnose)diagnose "${2:-}";;apply)apply_ip "${2:-}";;status)status;;__probe)CONNECT_TIMEOUT="${CFA_ENTRY_CONNECT_TIMEOUT:-3}";probe "${2:-}" "${3:-}">>"${CFA_ENTRY_RESULTS_FILE:?}";;help|-h|--help|'')usage;;*)usage>&2;exit 1;;esac
