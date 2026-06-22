#!/usr/bin/env python3
"""QuotaCard 独立数据抓取（不依赖 ai-limit 项目）。

- Claude：浏览器 cookie → claude.ai usage API（curl_cffi 过 Cloudflare）
- Codex ：chatgpt.com web → 失败回退本地 ~/.codex/sessions 快照
输出一行 JSON 到 stdout。
"""
import os
import sys
import json
import datetime
import pathlib

PROXY = os.environ.get("AI_LIMIT_PROXY", "")   # 默认直连；需要代理时由 app 通过环境变量传入
TIMEOUT = 15
CODEX_BASE = pathlib.Path.home() / ".codex" / "sessions"
# QuotaCard 自己的「上次成功」缓存（独立于 ai-limit），抓取失败时兜底显示
SUPPORT = pathlib.Path.home() / "Library" / "Application Support" / "QuotaCard"
LAST = SUPPORT / "last.json"
UA = ("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 "
      "(KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36")
# curl_cffi 的 TLS/JA3 指纹版本。实测「chrome」(最新, ~chrome136) 的指纹会被
# claude.ai / chatgpt.com 的 Cloudflare 间歇性挑战（~17% 通过）；而「chrome124」
# 稳定通过（12/12）。可用 AI_LIMIT_IMPERSONATE 覆盖。
IMPERSONATE = os.environ.get("AI_LIMIT_IMPERSONATE", "chrome124")


def _http_get(url, headers, timeout=TIMEOUT):
    """优先 curl_cffi 模拟 Chrome 指纹（过 Cloudflare）；不可用时退回 urllib。"""
    proxies = {"http": PROXY, "https": PROXY} if PROXY else None
    try:
        from curl_cffi import requests as creq
    except Exception:
        creq = None
    if creq is not None:
        h = dict(headers)
        h.pop("User-Agent", None)
        r = creq.get(url, headers=h, proxies=proxies, impersonate=IMPERSONATE, timeout=timeout)
        return r.status_code, (lambda n, d=None: r.headers.get(n, d)), r.content
    import urllib.request
    import urllib.error
    req = urllib.request.Request(url, headers=headers)
    px = {"http": PROXY, "https": PROXY} if PROXY else {}
    opener = urllib.request.build_opener(urllib.request.ProxyHandler(px))
    try:
        with opener.open(req, timeout=timeout) as resp:
            return resp.status, (lambda n, d=None: resp.headers.get(n, d)), resp.read()
    except urllib.error.HTTPError as e:
        return e.code, (lambda n, d=None: e.headers.get(n, d)), e.read()


def _looks_cf(get_header, body):
    if get_header("cf-mitigated"):
        return True
    low = body[:600].decode(errors="replace").lower()
    return any(m in low for m in ("just a moment", "challenge-platform", "/cdn-cgi/", "请验证您是真人"))


def _get_retry(url, headers, attempts=4):
    """对 Cloudflare 间歇性挑战重试（claude.ai 时好时坏，重试几次成功率大增）。"""
    last = None
    for _ in range(attempts):
        last = _http_get(url, headers)
        st, gh, body = last
        if not (st >= 400 and _looks_cf(gh, body)):
            return last
    return last


def _cookies_for(domain):
    import browser_cookie3
    for loader in (browser_cookie3.chrome, browser_cookie3.firefox):
        try:
            jar = loader(domain_name=domain)
            cookies = [(c.name, c.value) for c in jar]
            if cookies:
                return cookies
        except Exception:
            pass
    return []


# ── Claude ────────────────────────────────────────────────────────────────────
def fetch_claude():
    try:
        import browser_cookie3  # noqa: F401
    except Exception:
        return {"error": "browser_cookie3 未安装"}
    cookies = _cookies_for(".claude.ai")
    if not cookies:
        return {"error": "未读到 claude.ai cookie，请在浏览器登录"}
    org = dict(cookies).get("lastActiveOrg", "")
    if not org:
        return {"error": "未读到 org ID，请打开 claude.ai"}
    cookie_header = "; ".join(f"{n}={v}" for n, v in cookies)

    def hdr(ref):
        return {"Cookie": cookie_header, "Accept": "application/json",
                "Accept-Language": "en-US,en;q=0.9", "Origin": "https://claude.ai",
                "Referer": ref, "User-Agent": UA, "Sec-Fetch-Dest": "empty",
                "Sec-Fetch-Mode": "cors", "Sec-Fetch-Site": "same-origin"}

    try:
        st, gh, body = _get_retry(f"https://claude.ai/api/organizations/{org}/usage",
                                  hdr("https://claude.ai/settings/usage"))
    except Exception as e:
        return {"error": f"网络错误 {e.__class__.__name__}"}
    if st >= 400:
        if _looks_cf(gh, body):
            return {"error": "claude.ai 触发 Cloudflare 验证"}
        if st in (401, 403):
            return {"error": "claude.ai 登录失效，请重新登录"}
        return {"error": f"HTTP {st}"}
    try:
        data = json.loads(body)
    except Exception:
        return {"error": "非 JSON 响应"}
    five = data.get("five_hour") or {}
    seven = data.get("seven_day") or {}

    plan = None
    try:
        st2, _gh2, body2 = _http_get(f"https://claude.ai/api/organizations/{org}",
                                     hdr("https://claude.ai/settings/billing"))
        if st2 < 400:
            d2 = json.loads(body2)
            caps = set(d2.get("capabilities") or [])
            rt = d2.get("raven_type")
            if rt == "enterprise":
                plan = "Enterprise"
            elif rt == "team":
                plan = "Team"
            elif "claude_max" in caps:
                plan = "Max"
            elif "claude_pro" in caps:
                plan = "Pro"
            elif "raven" in caps:
                plan = "Enterprise"
            elif "chat" in caps:
                plan = "Free"
    except Exception:
        pass

    def left(w):
        return int(round(100 - float(w.get("utilization", 0)))) if w else None

    return {"5h_left": left(five), "7d_left": left(seven),
            "5h_reset": five.get("resets_at"), "7d_reset": seven.get("resets_at"),
            "plan": plan}


# ── Codex（直接读本地快照：准、快、不经 Cloudflare）──────────────────────────
def _codex_snapshot():
    if not CODEX_BASE.exists():
        return None
    files = sorted(CODEX_BASE.rglob("*.jsonl"), key=lambda p: p.stat().st_mtime, reverse=True)[:8]
    # 按 limit_id 分桶，各取最新一条。实验模型（如 GPT-5.x-Codex-Spark，limit_id
    # "codex_bengalfox"）有独立配额，往往恰好是时间最新的记录，会把读数污染成 0% 已用
    # → 100% 剩余。codex /status 展示的是主账号桶 limit_id == "codex"，故优先它。
    buckets = {}  # limit_id -> (ts_str, rate_limits)
    for jf in files:
        try:
            with open(jf, "rb") as f:
                f.seek(0, 2)
                size = f.tell()
                f.seek(max(0, size - 512 * 1024))
                tail = f.read().decode(errors="replace")
        except Exception:
            continue
        for line in tail.splitlines():
            if '"token_count"' not in line or '"rate_limits"' not in line:
                continue
            try:
                rec = json.loads(line)
            except Exception:
                continue
            if rec.get("type") != "event_msg":
                continue
            pl = rec.get("payload") or {}
            if pl.get("type") != "token_count":
                continue
            rl = pl.get("rate_limits")
            if not rl:
                continue
            lid = rl.get("limit_id") or ""
            ts = rec.get("timestamp", "")
            if lid not in buckets or ts > buckets[lid][0]:
                buckets[lid] = (ts, rl)
    if not buckets:
        return None
    if "codex" in buckets:
        best_ts, best_rl = buckets["codex"]
    else:
        best_ts, best_rl = max(buckets.values(), key=lambda x: x[0])
    p = best_rl.get("primary") or {}
    s = best_rl.get("secondary") or {}
    stale = ""
    try:
        dt = datetime.datetime.fromisoformat(best_ts.replace("Z", "+00:00"))
        secs = (datetime.datetime.now(datetime.timezone.utc) - dt).total_seconds()
        stale = (f"本地 · {int(secs // 60)} 分钟前" if secs < 3600
                 else f"本地 · {int(secs // 3600)} 小时前")
    except Exception:
        pass

    now_unix = datetime.datetime.now(datetime.timezone.utc).timestamp()

    def win(w):
        if not w:
            return (None, None, None)
        used = w.get("used_percent", 0)
        reset = w.get("resets_at")
        if reset and now_unix > reset:        # 快照里的重置点已过 → 窗口应已重置，推断恢复满额
            return (100, None, "已重置")
        return (int(round(100 - used)), reset, None)

    p5, r5, n5 = win(p)
    p7, r7, n7 = win(s)
    return {"5h_left": p5, "7d_left": p7,
            "5h_reset": r5, "7d_reset": r7,
            "5h_note": n5, "7d_note": n7,
            "plan": best_rl.get("plan_type"), "stale": stale}


def _chatgpt_headers(cookie_header, bearer=None):
    h = {"Cookie": cookie_header, "Accept": "application/json",
         "Accept-Language": "en-US,en;q=0.9",
         "Referer": "https://chatgpt.com/codex/cloud/settings/analytics",
         "Origin": "https://chatgpt.com", "User-Agent": UA,
         "Sec-Fetch-Dest": "empty", "Sec-Fetch-Mode": "cors",
         "Sec-Fetch-Site": "same-origin"}
    if bearer:
        h["Authorization"] = f"Bearer {bearer}"
    return h


def fetch_codex_web():
    """chatgpt.com 实时合并用量（Cloud + CLI），与 `codex /status` 一致。
    只读分析接口，不会触发新的 5h 窗口。被 Cloudflare 拦或未登录则返回 error，交由上层回退本地。"""
    cookies = _cookies_for(".chatgpt.com")
    if not cookies:
        return {"error": "未读到 chatgpt.com cookie"}
    ch = "; ".join(f"{n}={v}" for n, v in cookies)
    # 1) 用 cookie 换 access token
    st, gh, body = _get_retry("https://chatgpt.com/api/auth/session", _chatgpt_headers(ch))
    if st >= 400:
        return {"error": "chatgpt.com 触发 Cloudflare 验证" if _looks_cf(gh, body) else f"session HTTP {st}"}
    try:
        token = json.loads(body).get("accessToken")
    except Exception:
        token = None
    if not token:
        return {"error": "chatgpt.com 未登录"}
    # 2) 拉取用量
    st, gh, body = _get_retry("https://chatgpt.com/backend-api/codex/usage",
                              _chatgpt_headers(ch, bearer=token))
    if st >= 400:
        if _looks_cf(gh, body):
            return {"error": "chatgpt.com 触发 Cloudflare 验证"}
        if st in (401, 403):
            return {"error": "chatgpt.com 登录失效或无 Codex 权限"}
        return {"error": f"usage HTTP {st}"}
    try:
        data = json.loads(body)
    except Exception:
        return {"error": "非 JSON 响应"}
    rl = data.get("rate_limit") or {}
    p = rl.get("primary_window") or {}
    s = rl.get("secondary_window") or {}

    def left(w):
        return int(round(100 - float(w.get("used_percent", 0)))) if w else None

    if left(p) is None and left(s) is None:
        return {"error": "无用量数据"}
    return {"5h_left": left(p), "7d_left": left(s),
            "5h_reset": p.get("reset_at"), "7d_reset": s.get("reset_at"),
            "5h_note": None, "7d_note": None,
            "plan": data.get("plan_type"), "stale": ""}   # 空 stale → 卡片显示「实时」


def fetch_codex():
    # 实时 web 优先（合并 Cloud+CLI，与 codex /status 一致）；被 CF 拦/未登录再回退本地快照
    web = fetch_codex_web()
    if not web.get("error") and (web.get("7d_left") is not None or web.get("5h_left") is not None):
        return web
    snap = _codex_snapshot()
    if snap:
        return snap
    return web if web.get("error") else {"error": "未找到本地快照（先用一次 codex CLI）"}


def _load_last():
    try:
        return json.loads(LAST.read_text(encoding="utf-8"))
    except Exception:
        return {}


def _save_last(d):
    try:
        SUPPORT.mkdir(parents=True, exist_ok=True)
        LAST.write_text(json.dumps(d, ensure_ascii=False), encoding="utf-8")
    except Exception:
        pass


def _age_note(ts, prefix):
    try:
        secs = datetime.datetime.now().timestamp() - float(ts)
    except Exception:
        return prefix
    if secs < 3600:
        return f"{prefix} {int(secs // 60)} 分钟前"
    if secs < 86400:
        return f"{prefix} {int(secs // 3600)} 小时前"
    return f"{prefix} {int(secs // 86400)} 天前"


def _merge(name, fetched, last, now):
    """成功则更新缓存；失败但有上次成功值则回退显示（带「上次成功」标注）。"""
    if not fetched.get("error"):
        last[name] = fetched
        last[name + "_at"] = now
        return fetched
    prev = last.get(name)
    if prev and prev.get("5h_left") is not None:
        out = dict(prev)
        out["stale"] = _age_note(last.get(name + "_at"), "上次成功")
        return out
    return fetched


def main():
    last = _load_last()
    now = datetime.datetime.now().timestamp()
    out = {"fetched_at": now, "claude": None, "codex": None}
    try:
        cl = fetch_claude()
    except Exception as e:
        cl = {"error": f"{e.__class__.__name__}"}
    try:
        cx = fetch_codex()
    except Exception as e:
        cx = {"error": f"{e.__class__.__name__}"}
    out["claude"] = _merge("claude", cl, last, now)
    out["codex"] = _merge("codex", cx, last, now)
    _save_last(last)
    sys.stdout.write(json.dumps(out, ensure_ascii=False))


if __name__ == "__main__":
    main()
