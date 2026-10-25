#!/bin/sh
# 全路径集成测试：用 tests/mock_api.py 模拟 InstaBox API，验证 keepalive.sh 的
# 每条代码路径：正常续租 / 8h 上限主动轮转 / 冷却等待唤醒 / 挂起自愈 / status / release。
set -u
cd "$(dirname "$0")/.."

PORT=${MOCK_PORT:-8999}
EVENTS=${TMPDIR:-/tmp}/instabox-mock-events.log
BASE=http://127.0.0.1:$PORT
PASS=0 FAIL=0

ok()   { printf '  PASS  %s\n' "$1"; PASS=$((PASS + 1)); }
bad()  { printf '  FAIL  %s\n' "$1"; FAIL=$((FAIL + 1)); }
contains() { printf '%s\n' "$1" | grep -q "$2"; }
check() { # <描述> <命令...>（命令退出码 0 = 通过）
	desc=$1; shift
	if "$@"; then ok "$desc"; else bad "$desc"; fi
}

ev() { c=$(grep -c "^$1 $2 " "$EVENTS" 2>/dev/null || true); printf '%s' "${c:-0}"; }
evz() { [ "$(ev "$1" "$2")" -eq 0 ]; }
ev1() { [ "$(ev "$1" "$2")" -ge 1 ]; }

setsid python3 tests/mock_api.py "$PORT" "$EVENTS" </dev/null >/dev/null 2>&1 &
MOCK_PID=$!
trap 'kill "$MOCK_PID" 2>/dev/null; kill -9 "$MOCK_PID" 2>/dev/null' EXIT INT TERM
i=0
while [ $i -lt 50 ]; do
	curl -s -o /dev/null -m 1 "$BASE/v1/machines" -H 'X-API-Key: ibk_test' && break
	i=$((i + 1)); sleep 0.2
done

printf '== 第 1 轮：全路径（续租 / 轮转 / 冷却 / 唤醒）==\n'
OUT1=$(INSTABOX_API_URL=$BASE INSTABOX_API_KEY=ibk_test sh scripts/keepalive.sh 2>&1); RC1=$?
printf '%s\n' "$OUT1" | sed 's/^/    /'

check '退出码为 0（无失败机器）' [ "$RC1" -eq 0 ]
check 'box-ok 仅续租（无 suspend/resume）' evz suspend m_ok
check 'box-ok 至少续租一次' ev1 lease m_ok
check 'box-due 触发主动轮转 suspend' ev1 suspend m_due
check 'box-due 轮转后 resume 唤醒' ev1 resume m_due
check 'box-due 轮转后重新续租' ev1 lease m_due
check 'box-cool 走冷却等待分支（原地等待后唤醒）' contains "$OUT1" 'box-cool 处于冷却'
check 'box-cool 冷却结束后被唤醒' ev1 resume m_cool
check 'box-cool 唤醒后已续租' ev1 lease m_cool
check 'box-wake（无冷却挂起）被自愈唤醒' ev1 resume m_wake
check 'box-wake 唤醒后已续租' ev1 lease m_wake
check '汇总统计非零（子 shell 计数修复生效）' contains "$OUT1" '机器 4 台'

printf '\n== 第 2 轮：轮转后计时已重置，应全部只续租 ==\n'
OUT2=$(INSTABOX_API_URL=$BASE INSTABOX_API_KEY=ibk_test sh scripts/keepalive.sh 2>&1); RC2=$?
printf '%s\n' "$OUT2" | sed 's/^/    /'
check '退出码为 0' [ "$RC2" -eq 0 ]
check '本轮无新的 suspend（轮转幂等）' evz suspend m_ok
check 'box-due 只出现一次 suspend' [ "$(ev suspend m_due)" -eq 1 ]

printf '\n== --status 模式 ==\n'
OUT3=$(INSTABOX_API_URL=$BASE INSTABOX_API_KEY=ibk_test sh scripts/keepalive.sh --status 2>&1); RC3=$?
printf '%s\n' "$OUT3" | sed 's/^/    /'
check '退出码为 0' [ "$RC3" -eq 0 ]
check '四台机器状态都被打印' contains "$OUT3" 'box-cool'

printf '\n== --release 模式 ==\n'
OUT4=$(INSTABOX_API_URL=$BASE INSTABOX_API_KEY=ibk_test sh scripts/keepalive.sh --release 2>&1); RC4=$?
printf '%s\n' "$OUT4" | sed 's/^/    /'
check '退出码为 0' [ "$RC4" -eq 0 ]

printf '\n== 异常路径：错误 key ==\n'
OUT5=$(INSTABOX_API_URL=$BASE INSTABOX_API_KEY=ibk_wrong sh scripts/keepalive.sh 2>&1); RC5=$?
printf '%s\n' "$OUT5" | sed 's/^/    /'
check '错误 key 时退出码非 0（Actions 会显红）' [ "$RC5" -ne 0 ]

printf '\n== 异常路径：未设置 key ==\n'
OUT6=$(INSTABOX_API_URL=$BASE sh scripts/keepalive.sh 2>&1); RC6=$?
printf '%s\n' "$OUT6" | sed 's/^/    /'
check '未设置 key 时退出码非 0' [ "$RC6" -ne 0 ]

printf '\n========================================\n'
printf '结果：%d 通过 / %d 失败\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] && exit 0
exit 1
