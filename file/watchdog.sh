#!/bin/bash
# 内存看门狗（由 start.sh 拉起，每 60 秒一轮）
#   1) 同类进程多于一个 -> 优先杀掉孤儿（PPID=1），保留守护循环拉起的那个；
#      "受监督"的实例不是恰好 1 个（例如存在两个守护循环）时，退回全杀交循环重建
#   2) 只剩一个但仍吃太多 -> 重启它（cloudflared 由 start.sh 里的守护循环自动拉起）
# 说明：本脚本不包含任何密钥；需要 token 时从 dashboard 进程的 /proc/<pid>/environ 读取。

cd /app || exit 1
LOG=/app/watchdog.log
CF_PAT='^\./cloudflared-linux-amd64'
DASH_PAT='^\./dashboard-linux-amd64'
ts()   { TZ=Asia/Shanghai date '+%F %T'; }
pids() { pgrep -f "$1" 2>/dev/null | sort -n; }
rss()  { local p t=0 v; for p in $(pids "$1"); do v=$(ps -o rss= -p "$p" 2>/dev/null | tr -d ' '); t=$((t + ${v:-0})); done; echo "$t"; }
cnt()  { pids "$1" | wc -l; }

# 去重：优先杀孤儿（PPID=1），保留受守护循环监督的那一个；异常情况全杀交循环重建
dedupe() {
    local pat="$1" name="$2" p all sup orph
    all=$(pids "$pat")
    [ "$(echo $all | wc -w)" -le 1 ] && return
    sup=""; orph=""
    for p in $all; do
        if [ "$(ps -o ppid= -p "$p" 2>/dev/null | tr -d ' ')" = "1" ]; then
            orph="$orph $p"
        else
            sup="$sup $p"
        fi
    done
    if [ "$(echo $sup | wc -w)" -eq 1 ] && [ -n "$orph" ]; then
        echo "[$(ts)] $name 多实例：杀掉孤儿$(echo $orph)，保留受监督实例$sup" >> "$LOG"
        for p in $orph; do kill -9 "$p" 2>/dev/null; done
    else
        echo "[$(ts)] $name 多实例($(echo $all | wc -w) 个，受监督 $(echo $sup | wc -w) 个)，全部杀掉交守护循环重建: $(echo $all | tr '\n' ' ')" >> "$LOG"
        for p in $all; do kill -9 "$p" 2>/dev/null; done
        sleep 3
    fi
}

dedupe "$CF_PAT" cloudflared
dedupe "$DASH_PAT" dashboard

if [ "$(cnt "$CF_PAT")" -eq 1 ] && [ "$(rss "$CF_PAT")" -gt 122880 ]; then
    echo "[$(ts)] cloudflared RSS=$(rss "$CF_PAT")KB >120MB -> restart" >> "$LOG"
    bash /app/restart-cf.sh >> "$LOG" 2>&1
fi

if [ "$(cnt "$DASH_PAT")" -eq 1 ] && [ "$(rss "$DASH_PAT")" -gt 204800 ]; then
    echo "[$(ts)] dashboard RSS=$(rss "$DASH_PAT")KB >200MB -> restart" >> "$LOG"
    pkill -9 -f "$DASH_PAT"
    for i in $(seq 1 10); do pgrep -f "$DASH_PAT" >/dev/null || break; sleep 1; done
    nohup ./dashboard-linux-amd64 >/dev/null 2>&1 &
fi

if [ -z "$(pids "$CF_PAT")" ]; then
    sleep 6                      # 先给守护循环 5 秒的重建窗口
    if [ -z "$(pids "$CF_PAT")" ]; then
        bash /app/restart-cf.sh >> "$LOG" 2>&1
    fi
fi
