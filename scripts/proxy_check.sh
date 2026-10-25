#!/bin/sh
# proxy_check.sh — 3x-ui 代理健康检查 + 自动恢复 + GitHub Issue 告警
# （从原 cat-bot workflow 内嵌脚本抽出，供 .github/workflows/keepalive.yml 每轮调用）
#
# 每轮动作：
#   1. WebSocket 握手检查 vless-ws 代理 + HTTP 检查 3x-ui 面板
#   2. 代理不可达 → 恢复流程：
#        a. 机器非 running → resume（失败用 start 兜底，按 HTTP 状态码判断，
#           修复了旧版 curl 不带 -f 时 409 也算成功、start 永远不触发的 bug）
#        b. 配置了 INSTABOX_SSH_KEY → SSH 检查/重启 3x-ui 容器并重新发布端口
#   3. 恢复后复检；仍不可达 → 创建/更新告警 Issue；恢复 → 自动关闭 Issue
#   4. FORCE_RESTART=1（手动 dispatch mode=restart）→ 先 POST /restart 再走恢复
#
# 环境变量：
#   PROXY_HOST / PROXY_PATH      vless-ws 代理（8443 端口转发）
#   PANEL_HOST / PANEL_PATH      3x-ui 面板（2053 端口转发）
#   INSTABOX_API_URL / INSTABOX_API_KEY
#   INSTABOX_SSH_KEY             可选。配置后启用 SSH 级恢复（强烈建议配置）
#   INSTABOX_SSH_HOST / INSTABOX_SSH_PORT / INSTABOX_SSH_USER
#   REPO / GH_TOKEN              Issue 告警用
#   FORCE_RESTART                可选，=1 时先重启机器
#
# 退出码：0 = 代理正常（或已恢复）；1 = 代理不可达且恢复失败
set -u

API=${INSTABOX_API_URL:-https://api.instabox.sh}
KEY=${INSTABOX_API_KEY:-}
PROXY_HOST=${PROXY_HOST:-}
PROXY_PATH=${PROXY_PATH:-/}
PANEL_HOST=${PANEL_HOST:-}
PANEL_PATH=${PANEL_PATH:-/}
SSH_KEY=${INSTABOX_SSH_KEY:-}
SSH_HOST=${INSTABOX_SSH_HOST:-api.instabox.sh}
SSH_PORT=${INSTABOX_SSH_PORT:-2222}
SSH_USER=${INSTABOX_SSH_USER:-}
REPO=${REPO:-}
GH_TOKEN=${GH_TOKEN:-}
FORCE_RESTART=${FORCE_RESTART:-0}
READONLY=${READONLY:-0}   # =1 时只检查不恢复不告警（status/release 模式用）

log() { printf '[proxy] %s\n' "$*"; }

# ---- WebSocket 握手检查（429 = 限速但服务在线，视为正常）------------------------
ws_check() { # -> 打印首行响应或 ERROR: ...
	python3 - <<'PYEOF' 2>&1 || printf 'ERROR: python failed'
import os, socket, ssl, base64

host = os.environ["WS_HOST"]
path = os.environ["WS_PATH"]
try:
    ctx = ssl.create_default_context()
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    s.settimeout(10)
    ss = ctx.wrap_socket(s, server_hostname=host)
    ss.connect((host, 443))
    key = base64.b64encode(os.urandom(16)).decode()
    req = (
        "GET " + path + " HTTP/1.1\r\n"
        "Host: " + host + "\r\n"
        "Upgrade: websocket\r\n"
        "Connection: Upgrade\r\n"
        "Sec-WebSocket-Key: " + key + "\r\n"
        "Sec-WebSocket-Version: 13\r\n"
        "\r\n"
    )
    ss.sendall(req.encode())
    resp = ss.recv(4096).decode(errors="replace")
    print(resp.split("\r\n")[0] if resp else "empty")
    ss.close()
except Exception as e:
    print("ERROR: " + str(e))
PYEOF
}

ws_ok() { printf '%s' "$1" | grep -q '101 Switching'; }
ws_limited() { printf '%s' "$1" | grep -q '429'; }

# ---- InstaBox API 小工具 --------------------------------------------------------
api_get_machines() {
	curl -sS -m 30 -X GET "$API/v1/machines" \
		-H "X-API-Key: $KEY" -H 'Accept: application/json' 2>/dev/null
}

machine_ids() { # -> 每行 "id<TAB>state"
	api_get_machines | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(0)
for m in d.get("machines") or []:
    print("%s\t%s" % (m.get("id") or "", m.get("state") or ""))' 2>/dev/null
}

machine_state() { # <id> -> state
	curl -sS -m 10 "$API/v1/machines/$1" -H "X-API-Key: $KEY" 2>/dev/null \
		| python3 -c 'import json,sys; print(json.load(sys.stdin).get("state",""))' 2>/dev/null
}

act_code() { # <id> <resume|start|restart> -> HTTP 状态码（带 Idempotency-Key）
	curl -sS -m 30 -X POST "$API/v1/machines/$1/$2" \
		-H "X-API-Key: $KEY" \
		-H "Idempotency-Key: pc-$2-$1-$$-$(date +%s)" \
		-o /dev/null -w '%{http_code}' 2>/dev/null || printf '0'
}

wake_machine() { # <id> -> 0 = 已 running。按状态码正确兜底，修复旧版 || 逻辑 bug
	c1=$(act_code "$1" resume)
	case "$c1" in
		200|202) log "  resume HTTP $c1" ;;
		*)
			c2=$(act_code "$1" start)
			case "$c2" in
				200|202) log "  resume HTTP $c1 → start HTTP $c2" ;;
				*) log "  resume HTTP $c1 → start HTTP $c2（均未成功，可能冷却中）"; return 1 ;;
			esac ;;
	esac
	i=0
	while [ "$i" -lt 6 ]; do
		sleep 10
		st=$(machine_state "$1")
		log "  等待唤醒... ($((i + 1))) state=${st:-?}"
		[ "$st" = "running" ] && return 0
		i=$((i + 1))
	done
	return 1
}

# ---- SSH 恢复（配置了 INSTABOX_SSH_KEY 才生效）----------------------------------
ssh_recovery() {
	[ -n "$SSH_KEY" ] || { log "  无 SSH key，仅执行 API 级恢复（配置 INSTABOX_SSH_KEY secret 可启用容器/端口级自愈）"; return 1; }
	mkdir -p ~/.ssh
	printf '%s\n' "$SSH_KEY" > ~/.ssh/id_ed25519
	chmod 600 ~/.ssh/id_ed25519
	ssh-keyscan -p "$SSH_PORT" "$SSH_HOST" >> ~/.ssh/known_hosts 2>/dev/null
	SSH_CMD="ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 -p $SSH_PORT $SSH_USER@$SSH_HOST"

	log "  通过 SSH 恢复..."
	DOCKER_STATUS=$($SSH_CMD 'docker ps --format "{{.Names}} {{.Status}}" 2>/dev/null' 2>/dev/null) || DOCKER_STATUS=""
	log "  Docker: ${DOCKER_STATUS:-（无输出）}"

	if printf '%s\n' "$DOCKER_STATUS" | grep -q '3x-ui.*Up'; then
		log "  容器正常，重新发布端口..."
		$SSH_CMD 'instabox-port publish 2053 --name 3xui-panel 2>/dev/null; instabox-port publish 8443 --name vless-ws 2>/dev/null' 2>/dev/null || true
		SSH_MSG="端口已重新发布"
	else
		log "  容器异常，尝试重启..."
		$SSH_CMD 'docker restart 3x-ui 2>/dev/null; sleep 5; instabox-port publish 2053 --name 3xui-panel 2>/dev/null; instabox-port publish 8443 --name vless-ws 2>/dev/null' 2>/dev/null || true
		SSH_MSG="Docker 已重启，端口已重新发布"
	fi
	return 0
}

# ---- Issue 告警 ------------------------------------------------------------------
find_alert_issue() { # -> issue 编号（空 = 无）
	[ -n "$GH_TOKEN" ] && [ -n "$REPO" ] || return 0
	curl -sS -m 10 "https://api.github.com/repos/$REPO/issues?state=open&labels=keepalive-alert" \
		-H "Authorization: token $GH_TOKEN" 2>/dev/null \
		| python3 -c 'import json,sys
try:
    issues = json.load(sys.stdin)
    print(issues[0]["number"] if issues else "")
except Exception:
    print("")' 2>/dev/null
}

alert_open() { # <title> <body>
	[ -n "$GH_TOKEN" ] && [ -n "$REPO" ] || return 0
	TITLE=$1 BODY=$2 python3 -c '
import json, os
print(json.dumps({"title": os.environ["TITLE"], "body": os.environ["BODY"],
                  "labels": ["keepalive-alert", "bug"]}))' \
		| curl -sS -m 10 -X POST "https://api.github.com/repos/$REPO/issues" \
			-H "Authorization: token $GH_TOKEN" -H 'Content-Type: application/json' \
			-d @- -o /dev/null 2>/dev/null \
		&& log "  已创建告警 Issue"
}

alert_comment() { # <number> <body>
	[ -n "$GH_TOKEN" ] && [ -n "$REPO" ] || return 0
	BODY=$2 python3 -c '
import json, os
print(json.dumps({"body": os.environ["BODY"]}))' \
		| curl -sS -m 10 -X POST "https://api.github.com/repos/$REPO/issues/$1/comments" \
			-H "Authorization: token $GH_TOKEN" -H 'Content-Type: application/json' \
			-d @- -o /dev/null 2>/dev/null \
		&& log "  已更新 Issue #$1"
}

alert_close() { # <number>
	[ -n "$GH_TOKEN" ] && [ -n "$REPO" ] || return 0
	curl -sS -m 10 -X PATCH "https://api.github.com/repos/$REPO/issues/$1" \
		-H "Authorization: token $GH_TOKEN" -H 'Content-Type: application/json' \
		-d '{"state":"closed","labels":["keepalive-alert","resolved"]}' -o /dev/null 2>/dev/null \
		&& log "  ✅ 代理已恢复，关闭告警 Issue #$1"
}

# ==================================================================================
# 主流程
# ==================================================================================
NOW=$(date -u '+%Y-%m-%d %H:%M:%S UTC')
log "=== 代理健康检查 $NOW ==="

[ -n "$PROXY_HOST" ] || { log '未配置 PROXY_HOST，跳过代理检查'; exit 0; }

# 手动 restart 模式：先重启机器
if [ "$FORCE_RESTART" = "1" ] && [ -n "$KEY" ]; then
	log "=== 手动触发重启 ==="
	for mid in $(machine_ids | cut -f1); do
		[ -n "$mid" ] || continue
		c=$(act_code "$mid" restart)
		log "  restart $mid -> HTTP $c"
	done
	sleep 30
fi

# 1. 检查代理 + 面板
export WS_HOST=$PROXY_HOST WS_PATH=$PROXY_PATH
WS_RESULT=$(ws_check)
PANEL_CODE=$(curl -s -o /dev/null -m 10 -w '%{http_code}' "https://$PANEL_HOST$PANEL_PATH" 2>/dev/null) || PANEL_CODE="000"

log "  代理 WebSocket: $WS_RESULT"
log "  面板: HTTP $PANEL_CODE (期望 200)"

PROXY_OK=false
if ws_ok "$WS_RESULT"; then PROXY_OK=true; fi
if ws_limited "$WS_RESULT"; then PROXY_OK=true; log "  (429 限速，服务在线)"; fi

RECOVERY_MSG=""
if [ "$PROXY_OK" = "false" ] && [ "$READONLY" = "1" ]; then
	log "⚠️ 代理不可达（只读模式，不触发恢复与告警）"
elif [ "$PROXY_OK" = "false" ]; then
	log "⚠️ 代理不可达，启动恢复流程..."

	# a. 机器不在 running → 唤醒（多台全处理）
	if [ -n "$KEY" ]; then
		machine_ids | while IFS='	' read -r mid mst; do
			[ -n "$mid" ] || continue
			log "  机器 $mid [$mst]"
			if [ "$mst" != "running" ]; then
				wake_machine "$mid" || log "  唤醒未完成 $mid"
			fi
		done
	fi

	# b. SSH 级恢复（容器 + 端口重发布）
	if ssh_recovery; then
		: # SSH_MSG 已在函数内设置
	else
		SSH_MSG="无 SSH key，仅执行 API 级恢复"
	fi
	[ -n "${SSH_MSG:-}" ] && RECOVERY_MSG="$SSH_MSG"

	# c. 复检
	sleep 5
	WS_RESULT2=$(ws_check)
	log "  恢复后检查: $WS_RESULT2"
	if ws_ok "$WS_RESULT2"; then
		log "  ✅ 代理已恢复"
		PROXY_OK=true
		RECOVERY_MSG="✅ 已自动恢复: ${RECOVERY_MSG:-SSH/API 级恢复}"
	elif ws_limited "$WS_RESULT2"; then
		log "  ✅ 代理已恢复（429 限速）"
		PROXY_OK=true
		RECOVERY_MSG="✅ 已自动恢复（429 限速）: ${RECOVERY_MSG:-}"
	else
		log "  ❌ 代理仍未恢复"
		RECOVERY_MSG="❌ 恢复失败: ${RECOVERY_MSG:-}"
	fi
fi

# 2. Issue 告警
EXISTING=$(find_alert_issue)
if [ "$PROXY_OK" = "false" ]; then
	ISSUE_BODY=$(printf '## ⚠️ InstaBox 代理不可达\n\n**时间**: %s\n**代理 WebSocket**: %s\n**面板**: HTTP %s\n\n**恢复操作**: %s\n\n---\n此 Issue 由 keepalive workflow 自动创建。代理恢复后会自动关闭。' \
		"$NOW" "$WS_RESULT" "$PANEL_CODE" "${RECOVERY_MSG:-}")
	if [ -n "$EXISTING" ]; then
		alert_comment "$EXISTING" "更新 $NOW: ${RECOVERY_MSG:-}"
	else
		alert_open '⚠️ 代理不可达告警' "$ISSUE_BODY"
	fi
elif [ -n "$EXISTING" ]; then
	alert_close "$EXISTING"
else
	log "✅ 一切正常"
fi

log "=== 完成 $(date -u '+%Y-%m-%d %H:%M:%S UTC') ==="
# 退出码语义：
#   代理可达 / 只读模式 / 已通过 Issue 告警 → exit 0（run 保持 success，链式持续不吵）
#   代理不可达且无法告警（无 GH_TOKEN/REPO）→ exit 1（用 run 显红兜底）
[ "$PROXY_OK" = "true" ] && exit 0
[ "$READONLY" = "1" ] && exit 0
[ -n "$GH_TOKEN" ] && [ -n "$REPO" ] && exit 0
exit 1
