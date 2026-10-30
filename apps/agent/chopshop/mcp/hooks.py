import json
import logging
import os
import re
import threading
import time

from ..agent import envelope, webhooks
from ..agent import events as agent_events
from . import config
from .fleet import ToolError

log = logging.getLogger("chopshop.mcp.hooks")

NAME = re.compile(r"^[A-Za-z0-9_.-]{1,64}$")
MIN_HEARTBEAT = 30
MAX_HEARTBEAT = 86400
TIMEOUT = 10
RETRY_DELAY = 2.0


class Hooks:
    def __init__(self, fleet, mcp, poster=None):
        self.fleet = fleet
        self.dir = mcp["state_dir"]
        self.interval = max(1, int(mcp.get("poll_interval") or 5))
        self.subs_path = os.path.join(self.dir, "subscriptions.json")
        self.cursors_path = os.path.join(self.dir, "cursors.json")
        self.poster = poster or agent_events._default_poster
        self._lock = threading.Lock()
        self._stop = threading.Event()
        self._beats = {}
        self._status = {}
        self._thread = None

    def _subs(self):
        return config.read_json_private(self.subs_path, {})

    def _save_subs(self, subs):
        config.write_json_private(self.subs_path, subs)

    def public(self, name, s):
        return {"name": name, "projects": s.get("projects"), "types": s.get("types"),
                "exclude_types": s.get("exclude_types"), "min_severity": s.get("min_severity"), "needs": s.get("needs"),
                "machines": s.get("machines"), "heartbeat_s": s.get("heartbeat_s") or 0,
                "signed": bool(s.get("secret_file")), "headers": bool(s.get("headers_file")),
                "created": s.get("created")}

    def list(self):
        with self._lock:
            return [self.public(n, s) for n, s in sorted(self._subs().items())]

    def subscribe(self, args):
        name = args.get("name")
        if not isinstance(name, str) or not NAME.match(name):
            raise ToolError("name: 1-64 caracteres [A-Za-z0-9_.-]")
        url, wfile = args.get("url"), args.get("webhook_file")
        if bool(url) == bool(wfile):
            raise ToolError("indica url o webhook_file (uno de los dos)")
        if url and (not isinstance(url, str) or not url.startswith(("https://", "http://")) or len(url) > 2048
                    or any(ord(c) < 33 for c in url)):
            raise ToolError("url debe ser http(s) sin espacios")
        if wfile:
            wfile = os.path.expanduser(str(wfile))
            if not os.path.isfile(wfile):
                raise ToolError("webhook_file no existe en la máquina del servidor MCP")
        try:
            opts = webhooks.validate({k: args.get(k) for k in ("projects", "types", "exclude_types", "min_severity",
                                                               "needs", "secret_file", "headers_file")})
        except webhooks.WebhookError as e:
            raise ToolError(str(e))
        for k in ("secret_file", "headers_file"):
            if opts.get(k):
                p = os.path.expanduser(opts[k])
                if not os.path.isfile(p) or os.stat(p).st_mode & 0o077:
                    raise ToolError(f"{k} debe existir en la máquina del servidor MCP con permisos 600")
        hb = args.get("heartbeat_s") or 0
        if isinstance(hb, bool) or not isinstance(hb, int) or (hb and not MIN_HEARTBEAT <= hb <= MAX_HEARTBEAT):
            raise ToolError(f"heartbeat_s: 0 (sin heartbeats) o entre {MIN_HEARTBEAT} y {MAX_HEARTBEAT}")
        machines = args.get("machines")
        if machines is not None:
            known = {m.name for m in self.fleet.machines()}
            if not isinstance(machines, list) or not machines or not set(machines) <= known:
                raise ToolError("machines: lista de hosts conocidos ({})".format(", ".join(sorted(known))))
        owned = False
        if url:
            wfile = os.path.join(self.dir, "hooks", name + ".url")
            config.write_private(wfile, url + "\n")
            owned = True
        sub = dict(opts, webhook_file=wfile, owned=owned, heartbeat_s=hb, machines=machines,
                   projects=opts.get("projects") or ["*"], created=envelope.iso(time.time()))
        with self._lock:
            subs = self._subs()
            prev = subs.get(name)
            subs[name] = sub
            self._save_subs(subs)
        if prev and prev.get("owned") and prev.get("webhook_file") != wfile:
            self._remove(prev["webhook_file"])
        self._beats.pop(name, None)
        return {"ok": True, "subscription": self.public(name, sub), "replaced": bool(prev)}

    def unsubscribe(self, name):
        with self._lock:
            subs = self._subs()
            sub = subs.pop(name, None)
            if sub is None:
                raise ToolError(f"suscripción desconocida: {name}")
            self._save_subs(subs)
        if sub.get("owned"):
            self._remove(sub.get("webhook_file"))
        self._beats.pop(name, None)
        return {"ok": True, "name": name}

    @staticmethod
    def _remove(path):
        try:
            os.remove(path)
        except (OSError, TypeError):
            pass

    def start(self):
        self._thread = threading.Thread(target=self._run, name="mcp-hooks", daemon=True)
        self._thread.start()

    def stop(self):
        self._stop.set()

    def _run(self):
        while not self._stop.is_set():
            try:
                self.tick()
            except Exception:
                log.exception("fallo en la pasada de webhooks")
            self._stop.wait(self.interval)

    def tick(self):
        with self._lock:
            subs = self._subs()
        if not subs:
            return
        wanted = set()
        for s in subs.values():
            wanted |= set(s.get("machines") or ["*"])
        ms = [m for m in self.fleet.machines() if "*" in wanted or m.name in wanted]
        cursors = config.read_json_private(self.cursors_path, {})
        res = self.fleet.each(lambda m: self._fetch(m, cursors.get(m.name)), ms)
        changed = False
        for m in ms:
            r = res.get(m.name) or {}
            ok = "error" not in r
            self._status[m.name] = {"ok": ok, "error": None if ok else r.get("error"), "checked": envelope.iso(time.time())}
            if not ok:
                continue
            for env in r["events"]:
                self._deliver(subs, m.name, env)
            if r["cursor"] != cursors.get(m.name):
                cursors[m.name] = r["cursor"]
                changed = True
        if changed:
            config.write_json_private(self.cursors_path, cursors)
        self._heartbeats(subs)

    def _fetch(self, m, cursor):
        if cursor is None:
            head = m.get("/events", {"after": 0, "limit": 1}).get("head_seq") or 0
            return {"events": [], "cursor": head}
        evs = []
        for _ in range(5):
            r = m.get("/events", {"after": cursor, "limit": 200})
            batch = r.get("events") or []
            evs += batch
            cursor = r.get("last_seq") or cursor
            if len(batch) < 200:
                break
        return {"events": evs, "cursor": cursor}

    def _matches(self, sub, host, env):
        if sub.get("machines") and host not in sub["machines"]:
            return False
        f = {"projects": sub.get("projects") or ["*"], "types": sub.get("types"), "events": [],
             "exclude_types": sub.get("exclude_types") or [], "min_severity": sub.get("min_severity"),
             "needs": sub.get("needs") or []}
        return webhooks.matches(f, env)

    def _deliver(self, subs, host, env):
        for name, sub in subs.items():
            if not self._matches(sub, host, env):
                continue
            body = webhooks.payload(dict(env, host=host, source="chopshop-mcp"))
            self._send(name, sub, body, env.get("type") or "event")

    def _send(self, name, sub, body, kind):
        data = json.dumps(body, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
        headers = {"X-Chopshop-Event": kind, "X-Chopshop-Subscription": name}
        for i in range(2):
            ok, detail, retry = webhooks.attempt(sub["webhook_file"], sub.get("secret_file"), data, headers,
                                                 self.poster, TIMEOUT, sub.get("headers_file"))
            log.info("webhook %s %s intento %d: %s", name, kind, i + 1, detail)
            if ok or not retry:
                return ok
            self._stop.wait(RETRY_DELAY)
        return False

    def _heartbeats(self, subs):
        now = time.monotonic()
        for name, sub in subs.items():
            hb = sub.get("heartbeat_s") or 0
            if not hb:
                continue
            last = self._beats.get(name)
            if last is not None and now - last < hb:
                continue
            self._beats[name] = now
            hosts = sub.get("machines") or sorted(self._status)
            body = {"type": "mcp.heartbeat", "ts": envelope.iso(time.time()), "source": "chopshop-mcp",
                    "subscription": name, "machines": {h: self._status.get(h) for h in hosts}}
            self._send(name, sub, body, "mcp.heartbeat")
