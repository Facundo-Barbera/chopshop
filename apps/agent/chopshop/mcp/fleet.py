import concurrent.futures
import os
import socket
import threading
import time
import urllib.parse

from ..agent import client as agent_client
from . import config

LOOPBACK = ("127.0.0.1", "localhost", "::1")
ACTIVE = ("running", "starting")
IDS_TTL = 60.0
DEFAULT_CAP = 4


class ToolError(Exception):
    pass


class Machine:
    def __init__(self, name, url, token, roles, cap, local, timeout):
        self.name, self.url, self.roles, self.cap, self.local = name, url, roles, cap, local
        self.client = agent_client.AgentClient(url=url, token_file="", timeout=timeout)
        self.client.token = token
        self.paired = bool(token)

    def get(self, path, params=None, timeout=None):
        return self.client.get(path, params=params, timeout=timeout)

    def post(self, path, body=None, timeout=None):
        return self.client.post(path, body, timeout=timeout)


def _is_loopback(url):
    return (urllib.parse.urlsplit(url).hostname or "") in LOOPBACK


def _norm_url(url):
    return str(url).strip().rstrip("/")


def specs(cfg, mcp):
    app = cfg.get("app") or {}
    out = []

    def add(name, url):
        url = _norm_url(url)
        if url and not any(s[0] == name or s[1] == url for s in out):
            out.append((name, url))

    if app.get("agent_url"):
        add("agente", app["agent_url"])
    for name, a in sorted((app.get("agents") or {}).items()):
        if isinstance(a, dict) and a.get("url") and a.get("enabled", True) is not False:
            add(str(name), a["url"])
    if mcp.get("include_local", True):
        agent = cfg.get("agent") or {}
        add(agent.get("machine_id") or socket.gethostname(), f"http://127.0.0.1:{int(agent.get('port') or 3790)}")
    return out


class Fleet:
    def __init__(self):
        self._ids = {}
        self._ids_at = 0.0
        self._threads = {}
        self._lock = threading.Lock()
        self._pool = concurrent.futures.ThreadPoolExecutor(max_workers=16, thread_name_prefix="fleet")

    def all_machines(self):
        cfg, mcp = config.load()
        creds = config.credentials(mcp)
        local_token = agent_client.read_token(os.path.expanduser((cfg.get("agent") or {}).get("token_file") or ""))
        per = mcp.get("machines") or {}
        out = []
        for name, url in specs(cfg, mcp):
            local = _is_loopback(url)
            extra = per.get(name) if isinstance(per.get(name), dict) else {}
            roles = [str(r) for r in (extra.get("roles") or [])]
            cap = int(extra.get("cap") or DEFAULT_CAP)
            token = creds.get(url) or (local_token if local else None)
            out.append(Machine(name, url, token, roles, cap, local, int(mcp.get("timeout") or 15)))
        return out

    def machines(self):
        ms = self.all_machines()
        self._refresh_ids(ms)
        with self._lock:
            ids = dict(self._ids)
        local_ids = {ids.get(m.url): m for m in ms if m.local and ids.get(m.url)}
        out = []
        for m in ms:
            twin = local_ids.get(ids.get(m.url)) if not m.local else None
            if twin is not None:
                twin.name, twin.roles, twin.cap = m.name, m.roles or twin.roles, m.cap
                continue
            out.append(m)
        return out

    def _refresh_ids(self, ms):
        now = time.monotonic()
        with self._lock:
            if now - self._ids_at < IDS_TTL and all(m.url in self._ids for m in ms):
                return
            self._ids_at = now
        res = self.each(lambda m: m.get("/health", timeout=5), ms)
        with self._lock:
            for m in ms:
                r = res.get(m.name)
                if isinstance(r, dict) and r.get("machine_id"):
                    self._ids[m.url] = r["machine_id"]

    def machine_id(self, m):
        with self._lock:
            return self._ids.get(m.url)

    def each(self, fn, machines=None):
        ms = machines if machines is not None else self.machines()
        futs = {m.name: self._pool.submit(fn, m) for m in ms}
        out = {}
        for name, f in futs.items():
            try:
                out[name] = f.result()
            except agent_client.AgentError as e:
                out[name] = {"error": str(e), "status": e.status}
            except Exception as e:  # noqa: BLE001
                out[name] = {"error": f"{type(e).__name__}: {str(e)[:300]}"}
        return out

    def get(self, name):
        ms = self.machines()
        for m in ms:
            if m.name == name or self.machine_id(m) == name:
                return m
        raise ToolError("host desconocido: {} (hay: {})".format(name, ", ".join(m.name for m in ms) or "ninguno"))

    def remember(self, thread_id, host):
        with self._lock:
            self._threads[thread_id] = host

    def locate(self, thread_id, host=None):
        if host:
            return self.get(host)
        with self._lock:
            known = self._threads.get(thread_id)
        if known:
            try:
                return self.get(known)
            except ToolError:
                pass
        res = self.each(lambda m: m.get("/threads", {"limit": 500}))
        for name, r in res.items():
            for t in (r.get("threads") or []) if isinstance(r, dict) else []:
                self.remember(t.get("thread_id"), name)
        with self._lock:
            known = self._threads.get(thread_id)
        if not known:
            raise ToolError(f"no encuentro el hilo {thread_id} en ninguna máquina: pasa host")
        return self.get(known)

    def snapshots(self, machines=None):
        return self.each(lambda m: m.get("/snapshot"), machines)

    def knows_project(self, m, snap, project):
        if any(p.get("name") == project for p in snap.get("projects") or []):
            return True
        try:
            res = m.get("/t3/projects")
        except agent_client.AgentError:
            return False
        for p in res.get("projects") or []:
            root = (p.get("workspace_root") or "").rstrip("/")
            if project in (p.get("id"), p.get("title")) or (root and os.path.basename(root) == project):
                return True
        return False

    def candidates(self, project=None, role=None):
        ms = self.machines()
        if role:
            ms = [m for m in ms if role in m.roles]
            if not ms:
                raise ToolError(f"ninguna máquina tiene el rol {role} ([mcp.machines.<nombre>] roles)")
        snaps = self.snapshots(ms)
        out = []
        for m in ms:
            s = snaps.get(m.name) or {}
            if s.get("error") or (s.get("agent") or {}).get("t3_ok") is False:
                continue
            if project and not self.knows_project(m, s, project):
                continue
            running = sum(1 for t in s.get("threads") or [] if t.get("status") in ACTIVE)
            out.append({"machine": m, "running": running})
        if not out:
            raise ToolError("ninguna máquina disponible{}{}".format(f" con el proyecto {project}" if project else "",
                                                                f" y el rol {role}" if role else ""))
        return out

    @staticmethod
    def choose(cands):
        free = [c for c in cands if c["running"] < c["machine"].cap]
        if not free:
            full = ", ".join(f"{c['machine'].name} {c['running']}/{c['machine'].cap}" for c in cands)
            raise ToolError(f"todas las máquinas candidatas están al tope ({full})")
        best = min(free, key=lambda c: (c["running"] / max(c["machine"].cap, 1), c["running"], c["machine"].name))
        best["running"] += 1
        return best["machine"]
