import fnmatch
import json
import logging
import socket
import threading
import time

from . import events, projection

log = logging.getLogger("chopshop.agent")

MAX_CLIENTS = 8
HEARTBEAT = 15.0
WRITE_TIMEOUT = 10.0
POLL = 1.0
MAX_BACKLOG = 2000
RETRY_MS = 3000
PAGE = 500
CLOSE_WAIT = 5.0


class Bus:
    def __init__(self):
        self._cv = threading.Condition()
        self._head = 0
        self._closed = False

    def publish(self, seq=None):
        with self._cv:
            if isinstance(seq, int) and seq > self._head:
                self._head = seq
            self._cv.notify_all()

    def wait(self, seq, timeout):
        with self._cv:
            if self._head <= seq and not self._closed and timeout > 0:
                self._cv.wait(timeout)
            return self._head

    def close(self):
        with self._cv:
            self._closed = True
            self._cv.notify_all()

    @property
    def closed(self):
        return self._closed


class _Gone(Exception):
    pass


class _Client:
    __slots__ = ("sock", "device", "closed")

    def __init__(self, sock, device):
        self.sock, self.device, self.closed = sock, device, False

    def cut(self):
        self.closed = True
        try:
            self.sock.shutdown(socket.SHUT_RDWR)
        except OSError:
            pass


def _types(raw):
    pats = [t.strip() for t in (raw or "").split(",") if t.strip()]
    return pats or None


def _int_or_none(v):
    try:
        n = int(str(v).strip())
    except (TypeError, ValueError):
        return None
    return n if n >= 0 else None


class StreamHub:
    def __init__(self, conn, cfg, projector=None, bus=None, clock=time.monotonic, max_clients=MAX_CLIENTS,
                 heartbeat=HEARTBEAT, write_timeout=WRITE_TIMEOUT, poll=POLL, sndbuf=None, device_active=None):
        self.conn, self.cfg = conn, cfg
        self.machine = cfg.get("machine_id")
        self.projector = projector or projection.Projector(conn, cfg)
        self.bus = bus or Bus()
        self.clock = clock
        self.max_clients, self.heartbeat, self.write_timeout, self.poll = max_clients, heartbeat, write_timeout, poll
        self.sndbuf = sndbuf
        self.device_active = device_active
        self._lock = threading.Lock()
        self._gone = threading.Condition(self._lock)
        self._clients = set()

    @property
    def active(self):
        with self._lock:
            return len(self._clients)

    def close(self, wait=CLOSE_WAIT):
        self.bus.close()
        with self._lock:
            clients = list(self._clients)
        for c in clients:
            c.cut()
        with self._gone:
            self._gone.wait_for(lambda: not self._clients, wait)

    def revoke(self, device_id):
        with self._lock:
            clients = [c for c in self._clients if c.device == device_id]
        for c in clients:
            c.cut()
        return len(clients)

    def serve(self, handler, ident, query):
        project = query.get("project") or None
        types = _types(query.get("types"))
        after = _int_or_none(handler.headers.get("Last-Event-ID"))
        if after is None:
            after = _int_or_none(query.get("after"))
        client = _Client(handler.connection, getattr(ident, "device", None))
        with self._lock:
            full = self.bus.closed or len(self._clients) >= self.max_clients
            if not full:
                self._clients.add(client)
        if full:
            handler.close_connection = True
            return handler._reply(503, {"error": "demasiadas conexiones de stream (máx. %d)" % self.max_clients}, {"Retry-After": "3"})
        try:
            sock = handler.connection
            sock.settimeout(self.write_timeout)
            if self.sndbuf:
                sock.setsockopt(socket.SOL_SOCKET, socket.SO_SNDBUF, self.sndbuf)
            handler.close_connection = True
            handler.send_response(200)
            for k, v in (("Content-Type", "text/event-stream; charset=utf-8"), ("Cache-Control", "no-store"),
                         ("X-Accel-Buffering", "no"), ("X-Content-Type-Options", "nosniff"), ("Connection", "close")):
                handler.send_header(k, v)
            handler.end_headers()
            self._loop(client, handler.wfile, after, project, types)
        except (_Gone, OSError):
            pass
        finally:
            with self._gone:
                self._clients.discard(client)
                self._gone.notify_all()
        return 200

    def _write(self, client, wfile, text):
        if client.closed:
            raise _Gone()
        wfile.write(text.encode("utf-8"))

    @staticmethod
    def _frame(event, data, eid=None):
        out = "event: %s\n" % event
        if eid is not None:
            out += "id: %d\n" % eid
        return out + "data: %s\n\n" % json.dumps(data, ensure_ascii=False, separators=(",", ":"))

    def _match(self, env, project, types):
        if project is not None and env.get("project") != project:
            return False
        return types is None or any(fnmatch.fnmatchcase(env.get("type") or "", p) for p in types)

    def _check(self, client):
        if client.closed or self.bus.closed:
            raise _Gone()
        if client.device and self.device_active and not self.device_active(client.device):
            raise _Gone()

    def _loop(self, client, wfile, after, project, types):
        head = events.last_seq(self.conn)
        lo = projection.min_seq(self.conn)
        resume = after is not None and after <= head and head - after <= MAX_BACKLOG and (lo == 0 or after >= lo - 1)
        self._write(client, wfile, "retry: %d\n\n" % RETRY_MS)
        if resume:
            self._write(client, wfile, self._frame("hello", {"api_version": projection.API_VERSION, "machine": self.machine,
                                                              "head_seq": head, "resume": "events"}))
            cursor = after
        else:
            st = self.projector.current()
            if project is not None:
                st = projection.filter_project(st, project)
            self._write(client, wfile, self._frame("hello", {"api_version": projection.API_VERSION, "machine": self.machine,
                                                              "head_seq": st["head_seq"], "resume": "snapshot"}))
            self._write(client, wfile, self._frame("state", st, st["head_seq"]))
            cursor = st["head_seq"]
        next_ping = self.clock() + self.heartbeat
        while True:
            self._check(client)
            page = projection.envelopes_after(self.conn, cursor, PAGE)
            for env in page:
                cursor = env["seq"]
                if self._match(env, project, types):
                    self._write(client, wfile, self._frame("envelope", env, env["seq"]))
            if len(page) >= PAGE:
                continue
            now = self.clock()
            if now >= next_ping:
                self._write(client, wfile, ": ping\n\n")
                next_ping = now + self.heartbeat
            self.bus.wait(cursor, min(self.poll, max(0.0, next_ping - self.clock())) or 0.01)
