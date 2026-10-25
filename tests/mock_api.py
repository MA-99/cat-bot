#!/usr/bin/env python3
"""InstaBox API mock：本地复刻 https://api.instabox.sh 的关键行为，
用于测试 scripts/keepalive.sh 的全部代码路径。

模拟的平台规则（与真实平台一致）：
  - X-API-Key 认证，key 固定为 ibk_test
  - PUT  activity-leases：非 running 机器回 409 machine_not_running
  - POST suspend/resume/start：缺 Idempotency-Key 回 400
  - 跑满 8 小时被平台挂起的机器带 cooldownUntil，冷却期内 resume/start
    回 409 machine_cooldown，冷却结束后才允许唤醒
  - 主动 suspend 不产生冷却，resume 后 runStartedAt 重置（连续运行计时清零）

用法： python3 tests/mock_api.py [PORT] [EVENTS_LOG]
事件日志记录每个关键操作（lease/suspend/resume/start），测试脚本据此断言。
"""
import json
import sys
import threading
from datetime import datetime, timedelta, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse

PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 8999
EVENTS = sys.argv[2] if len(sys.argv) > 2 else "/tmp/instabox-mock-events.log"
API_KEY = "ibk_test"


def iso(dt):
    return dt.strftime("%Y-%m-%dT%H:%M:%S.") + "%03dZ" % (dt.microsecond // 1000)


def now():
    return datetime.now(timezone.utc)


def parse_iso(s):
    return datetime.fromisoformat(s.replace("Z", "+00:00"))


MACHINES = {
    "m_ok": {
        "id": "m_ok", "name": "box-ok", "state": "running",
        "maxRunMinutes": 480, "runStartedAt": iso(now() - timedelta(minutes=100)),
        "cooldownUntil": None, "autoSuspendAfterSeconds": 1800,
    },
    "m_due": {
        "id": "m_due", "name": "box-due", "state": "running",
        "maxRunMinutes": 480, "runStartedAt": iso(now() - timedelta(minutes=478)),
        "cooldownUntil": None, "autoSuspendAfterSeconds": 1800,
    },
    "m_cool": {
        "id": "m_cool", "name": "box-cool", "state": "suspended",
        "maxRunMinutes": 480, "runStartedAt": None,
        "cooldownUntil": iso(now() + timedelta(seconds=30)), "autoSuspendAfterSeconds": 1800,
    },
    "m_wake": {
        "id": "m_wake", "name": "box-wake", "state": "suspended",
        "maxRunMinutes": 480, "runStartedAt": None,
        "cooldownUntil": None, "autoSuspendAfterSeconds": 1800,
    },
}
LEASES = {}
LOCKS = {mid: threading.Lock() for mid in MACHINES}


def log_event(ev, mid, extra=""):
    # 统一三段式「ev mid extra」，extra 为空也保留尾随空格，方便 grep -c '^ev mid ' 计数
    with open(EVENTS, "a") as f:
        f.write("%s %s %s\n" % (ev, mid, extra))


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *args):
        pass

    def _send(self, code, obj):
        body = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _authed(self):
        if self.headers.get("X-API-Key") != API_KEY:
            self._send(401, {"error": {"code": "invalid_api_key"}})
            return False
        return True

    def _path_parts(self):
        return [p for p in urlparse(self.path).path.split("/") if p]

    def _read_body(self):
        n = int(self.headers.get("Content-Length") or 0)
        if n <= 0:
            return {}
        return json.loads(self.rfile.read(n) or b"{}")

    def _public(self, m):
        return {k: v for k, v in m.items() if k != "lease"}

    def do_GET(self):
        if not self._authed():
            return
        parts = self._path_parts()
        if parts == ["v1", "machines"]:
            return self._send(200, {"machines": [self._public(m) for m in MACHINES.values()]})
        if len(parts) == 3 and parts[:2] == ["v1", "machines"] and parts[2] in MACHINES:
            return self._send(200, self._public(MACHINES[parts[2]]))
        self._send(404, {"error": {"code": "not_found"}})

    def do_PUT(self):
        if not self._authed():
            return
        parts = self._path_parts()
        if len(parts) == 5 and parts[:2] == ["v1", "machines"] and parts[3] == "activity-leases":
            mid, lease_name = parts[2], parts[4]
            if mid not in MACHINES:
                return self._send(404, {"error": {"code": "not_found"}})
            m = MACHINES[mid]
            body = self._read_body()
            ttl = body.get("ttlSeconds")
            if not isinstance(ttl, int) or not (30 <= ttl <= 3600):
                return self._send(400, {"error": {"code": "ttl_out_of_range", "ttlSeconds": ttl}})
            if m["state"] != "running":
                return self._send(409, {"error": {
                    "code": "machine_not_running", "message": "machine is not running"}})
            exp = iso(now() + timedelta(seconds=ttl))
            LEASES[(mid, lease_name)] = exp
            log_event("lease", mid, "ttl=%d" % ttl)
            return self._send(200, {"name": lease_name, "ttlSeconds": ttl, "expiresAt": exp})
        self._send(404, {"error": {"code": "not_found"}})

    def do_DELETE(self):
        if not self._authed():
            return
        parts = self._path_parts()
        if len(parts) == 5 and parts[:2] == ["v1", "machines"] and parts[3] == "activity-leases":
            mid, lease_name = parts[2], parts[4]
            if LEASES.pop((mid, lease_name), None) is None:
                return self._send(404, {"error": {"code": "lease_not_found"}})
            self.send_response(204)
            self.send_header("Content-Length", "0")
            self.end_headers()
            return
        self._send(404, {"error": {"code": "not_found"}})

    def do_POST(self):
        if not self._authed():
            return
        parts = self._path_parts()
        if len(parts) == 4 and parts[:2] == ["v1", "machines"] and parts[3] in ("suspend", "resume", "start"):
            mid, action = parts[2], parts[3]
            if mid not in MACHINES:
                return self._send(404, {"error": {"code": "not_found"}})
            if not self.headers.get("Idempotency-Key"):
                return self._send(400, {"error": {"code": "idempotency_key_required"}})
            m = MACHINES[mid]
            with LOCKS[mid]:
                if action == "suspend":
                    if m["state"] != "running":
                        return self._send(409, {"error": {
                            "code": "machine_not_running", "message": "machine is not running"}})
                    m["state"] = "suspended"
                    m["runStartedAt"] = None
                    for key in [k for k in LEASES if k[0] == mid]:
                        LEASES.pop(key, None)
                    log_event("suspend", mid)
                    return self._send(202, {"state": "suspended"})
                cu = m.get("cooldownUntil")
                if cu and parse_iso(cu) > now():
                    return self._send(409, {"error": {
                        "code": "machine_cooldown", "cooldownUntil": cu,
                        "message": "machine is cooling down, cannot wake until cooldown ends"}})
                m["state"] = "running"
                m["runStartedAt"] = iso(now())
                m["cooldownUntil"] = None
                log_event(action, mid)
                return self._send(202, {"state": "running"})
        self._send(404, {"error": {"code": "not_found"}})


def main():
    open(EVENTS, "w").close()
    srv = ThreadingHTTPServer(("127.0.0.1", PORT), Handler)
    print("mock api listening on 127.0.0.1:%d, events -> %s" % (PORT, EVENTS), flush=True)
    srv.serve_forever()


if __name__ == "__main__":
    main()
