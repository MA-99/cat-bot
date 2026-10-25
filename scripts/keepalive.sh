#!/bin/sh
# instabox-gh-keepalive — 部署在 GitHub Actions 上的 InstaBox 看门狗
#
# 一轮做三件事（对每台机器）：
#   1. 续租 activity lease（压住"空闲 30 分钟自动挂起"）
#   2. 监控 remainingMinutes（离 8 小时运行上限的剩余分钟），快到上限时
#      主动 suspend → resume 清零连续运行计时，绕开平台强制挂起 + 10 分钟冷却
#   3. 机器已被挂起/停掉（409 machine_not_running）时自动唤醒；处于 10 分钟冷却
#      （machine_cooldown）时按 cooldownUntil 决定本轮等待唤醒还是下轮再救
#
# 用法（通常由 .github/workflows/keepalive.yml 调用，也可手动跑）：
#   INSTABOX_API_KEY=ibk_xxx sh scripts/keepalive.sh            # 保活一轮（默认）
#   INSTABOX_API_KEY=ibk_xxx sh scripts/keepalive.sh --status   # 只看状态
#   INSTABOX_API_KEY=ibk_xxx sh scripts/keepalive.sh --release  # 释放租约
#   INSTABOX_API_KEY=ibk_xxx sh scripts/keepalive.sh --help
#
# 环境变量（都有默认值，一般只需要配 INSTABOX_API_KEY）：
#   INSTABOX_API_KEY             必填。ibk_...，多把 key 逗号分隔，无限叠加
#   INSTABOX_MACHINE             可选。机器名 / m_... id，逗号分隔；留空 = 该 key 名下全部
#   INSTABOX_LEASE               租约名，默认 keepalive
#   INSTABOX_LEASE_TTL           租约秒数 30-3600，默认 3600（GitHub cron 有延迟，必须用大 TTL）
#   INSTABOX_CYCLE               1（默认）= 快到 8 小时上限时主动轮转；0 = 只续租不自愈
#   INSTABOX_CYCLE_MARGIN        距上限剩余几分钟时触发轮转，默认 30
#   INSTABOX_CYCLE_HOLD_MIN/MAX  轮转时 suspend 后随机停几秒再 resume，默认 5-15
#   INSTABOX_COOLDOWN_WAIT_MAX   冷却剩余低于多少秒时本轮原地等待并唤醒，默认 480
#   INSTABOX_WAKE_TRIES/GAP      唤醒后轮询 state 的次数/间隔，默认 12/5 秒
#   INSTABOX_API_URL             默认 https://api.instabox.sh
#
# 依赖：curl + (jq 或 python3)。GitHub Actions ubuntu-latest 全部自带。
set -u

API=${INSTABOX_API_URL:-https://api.instabox.sh}
KEYS=${INSTABOX_API_KEY:-}
MACHINE_FILTER=${INSTABOX_MACHINE:-}
LEASE=${INSTABOX_LEASE:-keepalive}
TTL=${INSTABOX_LEASE_TTL:-3600}
CYCLE=${INSTABOX_CYCLE:-1}
MARGIN=${INSTABOX_CYCLE_MARGIN:-30}
HOLD_MIN=${INSTABOX_CYCLE_HOLD_MIN:-5}
HOLD_MAX=${INSTABOX_CYCLE_HOLD_MAX:-15}
COOLDOWN_WAIT_MAX=${INSTABOX_COOLDOWN_WAIT_MAX:-480}
WAKE_TRIES=${INSTABOX_WAKE_TRIES:-12}
WAKE_GAP=${INSTABOX_WAKE_GAP:-5}
MODE=run

for a in "$@"; do
	case "$a" in
		--status|-s) MODE=status ;;
		--release|-r) MODE=release ;;
		--once|-1) MODE=run ;;
		--help|-h|h)
			sed -n '2,/^set -u$/p' "$0" | sed -e 's/^# \?//' -e '$d'
			exit 0 ;;
		*) printf '未知参数: %s（--help 看用法）\n' "$a" >&2; exit 2 ;;
	esac
done

log() { printf '[%s] %s\n' "$(date -u '+%Y-%m-%d %H:%M:%SZ')" "$*"; }
has() { command -v "$1" >/dev/null 2>&1; }
mask() {
	n=${#1}
	if [ "$n" -le 12 ]; then printf '%s' "$1"; else
		printf '%s…%s' "$(printf %s "$1" | cut -c1-8)" "$(printf %s "$1" | cut -c$((n - 3))-$n)"
	fi
}

[ -n "$(printf '%s' "$KEYS" | tr -d ' 	\n')" ] || { printf '错误: 未设置 INSTABOX_API_KEY\n' >&2; exit 1; }
has curl || { printf '错误: 缺 curl\n' >&2; exit 1; }
has jq || has python3 || { printf '错误: 需要 jq 或 python3（解析 API 响应）\n' >&2; exit 1; }
case "$TTL" in ''|*[!0-9]*) printf '错误: TTL 必须是数字: %s\n' "$TTL" >&2; exit 1 ;; esac
if [ "$TTL" -lt 30 ] || [ "$TTL" -gt 3600 ]; then
	printf '错误: TTL 必须在 30-3600 秒之间（当前 %s）\n' "$TTL" >&2; exit 1
fi

# ---- JSON / 时间工具：jq 优先，python3 兜底 -----------------------------------
json_field() { # <json> <key> -> 顶层字段值（字符串去引号；null/缺失输出空）
	j=$1 k=$2
	if has jq; then
		v=$(printf '%s' "$j" | jq -r --arg k "$k" '(.[$k] // empty) | if type == "string" then . else tostring end' 2>/dev/null) \
			&& { printf '%s\n' "$v"; return 0; }
	fi
	printf '%s' "$j" | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(0)
v = d.get(sys.argv[1]) if isinstance(d, dict) else None
if v is None or v == "":
    sys.exit(0)
if isinstance(v, bool):
    print("true" if v else "false")
elif isinstance(v, int):
    print(v)
elif isinstance(v, float) and v.is_integer():
    print(int(v))
elif isinstance(v, float):
    print(v)
else:
    print(str(v))' "$k" 2>/dev/null
}

machines_rows() { # <machines json> -> 每行 "id<TAB>name<TAB>state"
	if has jq; then
		rows=$(printf '%s' "$1" | jq -r '.machines[]? | [.id, .name, .state] | @tsv' 2>/dev/null) \
			&& { printf '%s\n' "$rows"; return 0; }
	fi
	printf '%s' "$1" | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(0)
for m in d.get("machines") or []:
    print("%s\t%s\t%s" % (m.get("id") or "", m.get("name") or "", m.get("state") or ""))' 2>/dev/null
}

iso_epoch() { # <ISO8601> -> epoch 秒；空/无效输出空
	s=$(printf '%s' "$1" | tr -d ' ')
	[ -n "$s" ] || return 0
	printf '%s' "$s" | python3 -c '
import sys
from datetime import datetime
s = sys.argv[1]
try:
    print(int(datetime.fromisoformat(s.replace("Z", "+00:00")).timestamp()))
except ValueError:
    pass' "$s" 2>/dev/null
}

randint() { awk -v a="$1" -v b="$2" 'BEGIN{srand(); printf "%d", a + int(rand() * (b - a + 1))}'; }

# ---- HTTP ---------------------------------------------------------------------
KEY=
HTTP_BODY=
HTTP_CODE=

http() { # <METHOD> <PATH> [JSON_BODY] -> 0=2xx；HTTP_CODE / HTTP_BODY
	m=$1 p=$2 d=${3:-}
	if [ -n "$d" ]; then
		resp=$(curl -sS -m 30 -X "$m" "$API$p" \
			-H "X-API-Key: $KEY" -H 'Content-Type: application/json' \
			-d "$d" -w '\n%{http_code}' 2>&1) || { HTTP_CODE=0; HTTP_BODY=$resp; return 1; }
	else
		resp=$(curl -sS -m 30 -X "$m" "$API$p" \
			-H "X-API-Key: $KEY" -w '\n%{http_code}' 2>&1) || { HTTP_CODE=0; HTTP_BODY=$resp; return 1; }
	fi
	HTTP_CODE=$(printf '%s' "$resp" | tail -n 1)
	HTTP_BODY=$(printf '%s' "$resp" | sed '$d')
	[ "$HTTP_CODE" = "200" ] || [ "$HTTP_CODE" = "204" ]
}

act_code() { # <id> <suspend|resume|start> -> 打印 HTTP 状态码（带 Idempotency-Key）
	curl -sS -m 30 -X POST "$API/v1/machines/$1/$2" \
		-H "X-API-Key: $KEY" \
		-H "Idempotency-Key: ka-$2-$1-$$-$(date +%s)" \
		-o /dev/null -w '%{http_code}' 2>/dev/null || printf '0'
}

body_match() { printf '%s' "$HTTP_BODY" | grep -Eqi "$1"; }
not_running_409() { [ "$HTTP_CODE" = "409" ] && body_match 'not_running|suspended|stopped'; }
cooldown_409() { [ "$HTTP_CODE" = "409" ] && body_match 'cooldown'; }

lease_one() { http PUT "/v1/machines/$1/activity-leases/$LEASE" "{\"ttlSeconds\":$TTL}"; }
release_one() { http DELETE "/v1/machines/$1/activity-leases/$LEASE"; }

wait_state() { # <id> <state> <tries> <gap> -> 0=达到
	i=0
	while [ "$i" -lt "$3" ]; do
		sleep "$4"
		if http GET "/v1/machines/$1"; then
			[ "$(json_field "$HTTP_BODY" state)" = "$2" ] && return 0
		fi
		i=$((i + 1))
	done
	return 1
}

wake_one() { # <id> <label> -> 0=已 running
	c1=$(act_code "$1" resume)
	case "$c1" in
		200|202) log "  resume HTTP $c1" ;;
		*)
			c2=$(act_code "$1" start)
			case "$c2" in
				200|202) log "  resume HTTP $c1 → start HTTP $c2" ;;
				*) log "  resume HTTP $c1 → start HTTP $c2（均未成功）"; return 1 ;;
			esac ;;
	esac
	wait_state "$1" running "$WAKE_TRIES" "$WAKE_GAP"
}

cycle_one() { # <id> -> 0=轮转完成且机器 running（8 小时计时已清零）
	c=$(act_code "$1" suspend)
	case "$c" in
		200|202) log "  suspend HTTP $c（连续运行计时清零）" ;;
		*) log "  轮转失败：suspend HTTP $c"; return 1 ;;
	esac
	if ! wait_state "$1" suspended 8 2; then
		log "  suspend 已发出但未进入 suspended，本轮放弃（下轮再看）"
		return 1
	fi
	hold=$(randint "$HOLD_MIN" "$HOLD_MAX")
	if [ "$hold" -gt 0 ]; then
		log "  停机 ${hold}s 后唤醒"
		sleep "$hold"
	fi
	c=$(act_code "$1" resume)
	case "$c" in
		200|202) : ;;
		*)
			c2=$(act_code "$1" start)
			case "$c2" in
				200|202) : ;;
				*) log "  resume HTTP $c → start HTTP $c2"; return 1 ;;
			esac ;;
	esac
	wait_state "$1" running "$WAKE_TRIES" "$WAKE_GAP"
}

# ---- 每台机器的主流程 -----------------------------------------------------------
TOTAL=0 OK=0 FAIL=0 COOLING=0 CYCLED=0
WAITED_THIS_ROUND=0
SUMMARY_ROWS=${TMPDIR:-/tmp}/instabox-keepalive-rows.$$

mask_ts() { date -u -d "$1" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || printf '%s' "$1"; }

record() { # <name> <state> <remain> <result> -> 追加结果行
	printf '| %s | %s | %s | %s |\n' "$1" "${2:-}" "${3:-}" "${4:-}" >> "$SUMMARY_ROWS"
}

process_machine() { # <id> <name>
	mid=$1 nm=${2:-$1}
	TOTAL=$((TOTAL + 1))
	if ! http GET "/v1/machines/$mid"; then
		log "读取机器失败 $nm HTTP $HTTP_CODE: $(printf '%s' "$HTTP_BODY" | cut -c1-160)"
		FAIL=$((FAIL + 1)); record "$nm" '?' '-' '读取失败'
		return 0
	fi
	info=$HTTP_BODY
	state=$(json_field "$info" state)
	started=$(iso_epoch "$(json_field "$info" runStartedAt)")
	cooldown=$(iso_epoch "$(json_field "$info" cooldownUntil)")
	maxrun=$(json_field "$info" maxRunMinutes)
	maxrun=${maxrun%.*}
	now=$(date +%s)

	remain_min=''
	if [ -n "$started" ] && [ -n "$maxrun" ] && [ "$maxrun" -gt 0 ] 2>/dev/null; then
		remain_min=$(( (started + maxrun * 60 - now + 59) / 60 ))
		[ "$remain_min" -lt 0 ] && remain_min=0
	fi
	remain_show=${remain_min:-n/a}
	[ "$remain_min" = "0" ] && remain_show=0

	if [ "$MODE" = status ]; then
		cu_iso=$(json_field "$info" cooldownUntil)
		if [ -n "$cu_iso" ]; then cu_show=$(mask_ts "$cu_iso"); else cu_show='-'; fi
		log "$nm state=$state 剩余=${remain_show}min 冷却至=$cu_show"
		record "$nm" "$state" "$remain_show" '仅状态'
		return 0
	fi

	if [ "$MODE" = release ]; then
		if release_one "$mid"; then
			log "已释放租约 $nm/$LEASE"; OK=$((OK + 1)); record "$nm" "$state" "$remain_show" '已释放'
		elif [ "$HTTP_CODE" = "404" ]; then
			log "租约本不存在 $nm/$LEASE"; OK=$((OK + 1)); record "$nm" "$state" "$remain_show" '无租约'
		else
			log "释放失败 $nm HTTP $HTTP_CODE"; FAIL=$((FAIL + 1)); record "$nm" "$state" "$remain_show" '释放失败'
		fi
		return 0
	fi

	# ---- 非运行态：冷却等待 或 直接唤醒 ----------------------------------------
	if [ "$state" != "running" ]; then
		if [ -n "$cooldown" ] && [ "$cooldown" -gt "$now" ]; then
			wait_s=$((cooldown - now))
			if [ "$wait_s" -le "$COOLDOWN_WAIT_MAX" ] && [ "$WAITED_THIS_ROUND" -eq 0 ]; then
				WAITED_THIS_ROUND=1
				log "$nm 处于冷却（剩 ${wait_s}s ≤ ${COOLDOWN_WAIT_MAX}s），本轮原地等待后唤醒"
				sleep $((wait_s + 3))
				if wake_one "$mid" "$nm" && lease_one "$mid"; then
					log "冷却结束唤醒成功 $nm，租约到期 $(json_field "$HTTP_BODY" expiresAt)"
					OK=$((OK + 1)); record "$nm" running '已重置' '冷却后唤醒'
				else
					log "冷却后唤醒/续租失败 $nm HTTP $HTTP_CODE"
					FAIL=$((FAIL + 1)); record "$nm" "$state" "$remain_show" '唤醒失败'
				fi
			else
				log "$nm 冷却剩 ${wait_s}s（> ${COOLDOWN_WAIT_MAX}s 或本轮已等待过），下轮再唤醒"
				COOLING=$((COOLING + 1)); record "$nm" "$state" "$remain_show" '冷却中·下轮救'
			fi
		else
			log "$nm 当前 state=$state，尝试唤醒"
			if wake_one "$mid" "$nm" && lease_one "$mid"; then
				log "唤醒成功 $nm，租约到期 $(json_field "$HTTP_BODY" expiresAt)"
				OK=$((OK + 1)); record "$nm" running '已重置' '自愈唤醒'
			else
				log "唤醒/续租失败 $nm HTTP $HTTP_CODE: $(printf '%s' "$HTTP_BODY" | cut -c1-160)"
				FAIL=$((FAIL + 1)); record "$nm" "$state" "$remain_show" '唤醒失败'
			fi
		fi
		return 0
	fi

	# ---- 运行态：快到 8 小时上限先主动轮转 --------------------------------------
	if [ "$CYCLE" = "1" ] && [ -n "$remain_min" ] && [ "$remain_min" -gt 0 ] && [ "$remain_min" -le "$MARGIN" ]; then
		log "$nm 距运行上限仅 ${remain_min}min（≤ ${MARGIN}min），主动轮转清零计时"
		if cycle_one "$mid" && lease_one "$mid"; then
			log "轮转完成 $nm，新租约到期 $(json_field "$HTTP_BODY" expiresAt)"
			OK=$((OK + 1)); CYCLED=$((CYCLED + 1)); record "$nm" running '已重置' '轮转'
		else
			log "轮转未完成 $nm，尝试直接续租兜底"
			if lease_one "$mid"; then
				log "兜底续租成功 $nm"; OK=$((OK + 1)); record "$nm" running "$remain_show" '轮转失败·已续租'
			elif not_running_409 && wake_one "$mid" "$nm" && lease_one "$mid"; then
				log "兜底唤醒成功 $nm"; OK=$((OK + 1)); record "$nm" running '已重置' '轮转失败·已唤醒'
			else
				log "兜底也失败 $nm HTTP $HTTP_CODE"
				FAIL=$((FAIL + 1)); record "$nm" running "$remain_show" '轮转+兜底失败'
			fi
		fi
		return 0
	fi

	# ---- 正常路径：续租；被挂起则唤醒 -------------------------------------------
	if lease_one "$mid"; then
		log "续租 ok $nm（剩 ${remain_show}min）到期 $(json_field "$HTTP_BODY" expiresAt)"
		OK=$((OK + 1)); record "$nm" running "$remain_show" '续租'
	elif not_running_409 && wake_one "$mid" "$nm" && lease_one "$mid"; then
		log "续租发现未运行，已唤醒并续租 $nm"
		OK=$((OK + 1)); record "$nm" running '已重置' '自愈唤醒'
	elif cooldown_409; then
		log "$nm 续租撞上冷却（HTTP 409 machine_cooldown），等待下轮处理"
		COOLING=$((COOLING + 1)); record "$nm" running "$remain_show" '冷却中·下轮救'
	else
		log "续租失败 $nm HTTP $HTTP_CODE: $(printf '%s' "$HTTP_BODY" | cut -c1-160)"
		FAIL=$((FAIL + 1)); record "$nm" running "$remain_show" '续租失败'
	fi
}

# ---- 多 key / 机器过滤 / 主循环 --------------------------------------------------
# 注意：两个循环都用「重定向文件」而不是管道喂 while——管道右侧是子 shell，
# 里面的 TOTAL/OK/FAIL 计数改了传不出来，汇总会永远归零。
: > "$SUMMARY_ROWS"

TMPBASE=${TMPDIR:-/tmp}
printf '%s\n' "$KEYS" | tr ',' '\n' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | grep -v '^$' \
	| awk '!seen[$0]++' > "$TMPBASE/ibk-keys.$$"
: > "$TMPBASE/ibk-rows.$$"
: > "$TMPBASE/ibk-sels.$$"

n=0
while IFS= read -r k; do
	n=$((n + 1))
	KEY=$k
	log "== key $n（$(mask "$k")）=="
	if ! http GET /v1/machines; then
		log "列机器失败 HTTP $HTTP_CODE: $(printf '%s' "$HTTP_BODY" | cut -c1-160)"
		FAIL=$((FAIL + 1))
		continue
	fi
	machines_rows "$HTTP_BODY" > "$TMPBASE/ibk-rows.$$"
	count=$(grep -c . "$TMPBASE/ibk-rows.$$" || true)
	if [ "${count:-0}" -eq 0 ]; then
		log "这把 key 名下没有机器"
		continue
	fi
	while IFS='	' read -r mid mname _mstate; do
		[ -n "$mid" ] || continue
		if [ -n "$MACHINE_FILTER" ]; then
			printf '%s\n' "$MACHINE_FILTER" | tr ',' '\n' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | grep -v '^$' \
				> "$TMPBASE/ibk-sels.$$"
			match=0
			while IFS= read -r sel; do
				if [ "$sel" = "$mid" ] || [ "$sel" = "$mname" ]; then match=1; break; fi
			done < "$TMPBASE/ibk-sels.$$"
			[ "$match" -eq 1 ] || continue
		fi
		process_machine "$mid" "$mname"
	done < "$TMPBASE/ibk-rows.$$"
done < "$TMPBASE/ibk-keys.$$"
rm -f "$TMPBASE/ibk-keys.$$" "$TMPBASE/ibk-rows.$$" "$TMPBASE/ibk-sels.$$" 2>/dev/null || true

# ---- 汇总 ----------------------------------------------------------------------
log "本轮汇总：机器 $TOTAL 台，成功 $OK（轮转 $CYCLED），冷却等待中 $COOLING，失败 $FAIL"

if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
	{
		printf '### InstaBox 看门狗 · %s\n\n' "$(date -u '+%Y-%m-%d %H:%M UTC')"
		printf '| 机器 | state | 距8h上限 | 本轮结果 |\n| --- | --- | --- | --- |\n'
		cat "$SUMMARY_ROWS"
		printf '\n- 成功 %s（其中主动轮转 %s）/ 共 %s；冷却等待 %s；失败 %s\n' "$OK" "$CYCLED" "$TOTAL" "$COOLING" "$FAIL"
	} >> "$GITHUB_STEP_SUMMARY" 2>/dev/null || true
fi
rm -f "$SUMMARY_ROWS" 2>/dev/null || true

[ "$FAIL" -eq 0 ] && exit 0
exit 1
