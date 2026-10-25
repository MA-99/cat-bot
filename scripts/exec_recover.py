#!/usr/bin/env python3
"""通过 InstaBox API exec 接口自动恢复 3x-ui 代理（不需要 SSH key）。

逻辑：
  1. 遍历 running 机器，用 exec 找有 3x-ui 容器的那台
  2. 容器没跑 → docker restart 3x-ui
  3. 从 3x-ui 数据库读面板端口 + vless inbound 端口
  4. 比对 instabox-port list 的转发端口是否匹配
  5. 不匹配 → unpublish 旧的 + publish 正确的

环境变量：INSTABOX_API_URL、INSTABOX_API_KEY
退出码：0 = 恢复成功 / 本就正常；1 = 未找到 3x-ui 或恢复失败
"""
import json, os, sys, time, urllib.request, urllib.error

API = os.environ.get("INSTABOX_API_URL", "https://api.instabox.sh")
KEY = os.environ.get("INSTABOX_API_KEY", "")


def api_exec(mid, cmd, retries=3):
    for attempt in range(retries):
        body = json.dumps({"cmd": cmd}).encode()
        r = urllib.request.Request(f"{API}/v1/machines/{mid}/exec", data=body, method="POST")
        r.add_header("X-API-Key", KEY)
        r.add_header("Content-Type", "application/json")
        try:
            with urllib.request.urlopen(r, timeout=30) as resp:
                d = json.loads(resp.read())
                return d.get("stdout", "").strip(), d.get("exitCode", -1)
        except urllib.error.HTTPError as e:
            if e.code == 502 and attempt < retries - 1:
                time.sleep(2); continue
            return "", -1
        except Exception:
            if attempt < retries - 1:
                time.sleep(2); continue
            return "", -1


def api_get(path):
    r = urllib.request.Request(f"{API}{path}")
    r.add_header("X-API-Key", KEY)
    with urllib.request.urlopen(r, timeout=20) as resp:
        return json.loads(resp.read())


def log(msg):
    print(f"[exec-recover] {msg}", flush=True)


if not KEY:
    log("未设置 INSTABOX_API_KEY")
    sys.exit(1)

# 1. 找有 3x-ui 的 running 机器
try:
    machines = api_get("/v1/machines").get("machines", [])
except Exception as e:
    log(f"列机器失败: {e}")
    sys.exit(1)

for m in machines:
    if m.get("state") != "running":
        continue
    mid = m["id"]
    name = m.get("name", mid)

    out, _ = api_exec(mid, "docker ps -a --format '{{.Names}} {{.Status}}' 2>/dev/null")
    if "3x-ui" not in out:
        continue

    log(f"在 {name} ({mid}) 上发现 3x-ui: {out.strip()}")

    # 2. 容器没跑 → 重启
    if "3x-ui Up" not in out:
        log("  3x-ui 容器未运行，重启...")
        api_exec(mid, "docker restart 3x-ui 2>&1")
        time.sleep(15)

    # 3. 读 3x-ui 实际端口
    panel_port, _ = api_exec(mid, """docker exec 3x-ui sqlite3 /etc/x-ui/x-ui.db "SELECT value FROM settings WHERE key='webPort';" 2>/dev/null""")
    vless_port, _ = api_exec(mid, """docker exec 3x-ui sqlite3 /etc/x-ui/x-ui.db "SELECT port FROM inbounds WHERE enable=1 LIMIT 1;" 2>/dev/null""")
    panel_port = panel_port.strip()
    vless_port = vless_port.strip()

    # sqlite3 可能不存在（不同镜像），跳过这台继续找下一台
    if not panel_port or not vless_port or "failed" in panel_port.lower() or "failed" in vless_port.lower() or "error" in panel_port.lower() or "error" in vless_port.lower():
        log(f"  无法读取端口（sqlite3 可能不存在），跳过 {name}")
        continue

    log(f"  面板端口={panel_port}, vless端口={vless_port}")

    # 4. 比对端口转发
    ports_out, _ = api_exec(mid, "instabox-port list 2>/dev/null")
    try:
        ports = json.loads(ports_out).get("ports", [])
    except Exception:
        ports = []

    fixed = False
    for cfg_name, actual_port in [("3xui-panel", panel_port), ("vless-reality", vless_port)]:
        # 找当前这个 name 的转发
        current = [p for p in ports if p.get("name") == cfg_name]
        if current and str(current[0].get("port")) == actual_port:
            log(f"  {cfg_name} 端口转发正常 ({actual_port})")
            continue
        # 需要修正：先 unpublish 旧的
        for p in current:
            old = p.get("port")
            log(f"  {cfg_name} 端口不匹配（当前 {old}，应为 {actual_port}），修正...")
            api_exec(mid, f"instabox-port unpublish {old} 2>&1")
        log(f"  发布 {cfg_name} 端口 {actual_port}...")
        api_exec(mid, f"instabox-port publish {actual_port} --name {cfg_name} 2>&1")
        fixed = True

    if fixed:
        log("  端口转发已修正")
    else:
        log("  端口转发全部正常，无需修正")

    log("恢复完成")
    sys.exit(0)

log("未找到运行 3x-ui 的机器")
sys.exit(1)
