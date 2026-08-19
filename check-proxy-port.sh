#!/usr/bin/env bash

set -u

host="${1:-}"
port="${2:-9051}"
interval="${3:-1}"

if [ -z "$host" ]; then
  printf '用法：%s <IP或域名> [端口] [间隔秒数]\n' "$0" >&2
  exit 1
fi

printf '持续检测 %s:%s（按 Ctrl+C 停止）\n' "$host" "$port"

while true; do
  printf '%s ' "$(date '+%Y-%m-%d %H:%M:%S')"
  nc -G 3 -vz "$host" "$port"
  sleep "$interval"
done
