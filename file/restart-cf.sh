#!/bin/bash
# 重启 cloudflared：只负责"杀"，拉起交给 start.sh 里的守护循环（5 秒级）；
# 120 秒还没起来才自己拉。脚本内不含密钥，token 从 dashboard 进程的 /proc/<pid>/environ 读。

cd /app || exit 1
case $(uname -m) in
    aarch64) ARCH="arm64" ;;
    *)       ARCH="amd64" ;;
esac
CF="cloudflared-linux-${ARCH}"

pkill -9 -f "$CF"

i=0
while [ "$i" -lt 120 ]; do
    pgrep -f "$CF" >/dev/null && break
    sleep 1
    i=$((i + 1))
done

if ! pgrep -f "$CF" >/dev/null; then
    DPID=$(pgrep -f "dashboard-linux-${ARCH}" | head -1)
    AUTH=$(tr '\0' '\n' < /proc/$DPID/environ 2>/dev/null | sed -n 's/^ARGO_AUTH=//p' | head -1)
    [ -z "$AUTH" ] && AUTH="${ARGO_AUTH:-}"
    TUNNEL_TOKEN="$AUTH" nohup "./$CF" tunnel --protocol http2 run >> /app/cloudflared.log 2>&1 &
    sleep 5
fi
pgrep -af "$CF"
