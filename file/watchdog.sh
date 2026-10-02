#!/bin/bash
# 内存看门狗（由 start.sh 拉起，每 60 秒一轮）
#   1) 同类进程多于一个 -> 只杀多余的（保留最老的那个），不断隧道
#   2) 只剩一个但仍吃太多 -> 重启它（cloudflared 由 start.sh 里的守护循环自动拉起）
# 说明：本脚本不包含任何密钥；需要 token 时从 dashboard 进程的 /proc/<pid>/environ 读取。

cd /app || exit 1
LOG=/app/watchdog.log
ts()   { TZ=Asia/Shanghai date '+%F %T'; }
pids() { pgrep -f "$1" 2>/dev/null | sort -n; }
rss()  { local p t=0 v; for p in $(pids "$1"); do v=$(ps -o rss= -p "$p" 2>/dev/null | tr -d ' '); t=$((t + ${v:-0})); done; echo "$t"; }
cnt()  { pids "$1" | wc -l; }

dedupe() {
    local list extra
    list=$(pids "$1")
    extra=$(echo "$list" | tail -n +2)
    if [ -n "$extra" ]; then
        echo "[$(ts)] $2 多实例，杀掉多余的: $(echo $extra | tr '\n' ' ')" >> "$LOG"
        for p in $extra; do kill -9 "$p" 2>/dev/null; done
        sleep 2
    fi
}

dedupe cloudflared-linux-amd64 cloudflared
dedupe dashboard-linux-amd64 dashboard

if [ "$(cnt cloudflared-linux-amd64)" -eq 1 ] && [ "$(rss cloudflared-linux-amd64)" -gt 122880 ]; then
    echo "[$(ts)] cloudflared RSS=$(rss cloudflared-linux-amd64)KB >120MB -> restart" >> "$LOG"
    bash /app/restart-cf.sh >> "$LOG" 2>&1
fi

if [ "$(cnt dashboard-linux-amd64)" -eq 1 ] && [ "$(rss dashboard-linux-amd64)" -gt 204800 ]; then
    echo "[$(ts)] dashboard RSS=$(rss dashboard-linux-amd64)KB >200MB -> restart" >> "$LOG"
    pkill -9 -f dashboard-linux-amd64
    for i in $(seq 1 10); do pgrep -f dashboard-linux-amd64 >/dev/null || break; sleep 1; done
    nohup ./dashboard-linux-amd64 >/dev/null 2>&1 &
fi

if [ -z "$(pids cloudflared-linux-amd64)" ]; then
    bash /app/restart-cf.sh >> "$LOG" 2>&1
fi
