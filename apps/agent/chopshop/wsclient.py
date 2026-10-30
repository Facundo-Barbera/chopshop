import base64
import hashlib
import os
import random
import socket
import ssl
import struct
import threading
import time
import urllib.parse

GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

OP_CONT = 0x0
OP_TEXT = 0x1
OP_BINARY = 0x2
OP_CLOSE = 0x8
OP_PING = 0x9
OP_PONG = 0xA

MAX_CONTROL = 125


class WSError(Exception):
    pass


class WSClosed(WSError):
    def __init__(self, code=None, reason=""):
        super().__init__(f"closed: {code} {reason}".strip())
        self.code = code
        self.reason = reason


def accept_key(key):
    return base64.b64encode(hashlib.sha1((key + GUID).encode("ascii")).digest()).decode("ascii")


def new_key():
    return base64.b64encode(os.urandom(16)).decode("ascii")


def apply_mask(mask_key, data):
    if not data:
        return b""
    n = len(data)
    reps = (mask_key * (n // 4 + 1))[:n]
    return (int.from_bytes(data, "big") ^ int.from_bytes(reps, "big")).to_bytes(n, "big")


def encode_frame(opcode, payload=b"", fin=True, mask=True, mask_key=None):
    if isinstance(payload, str):
        payload = payload.encode("utf-8")
    if opcode >= OP_CLOSE and (len(payload) > MAX_CONTROL or not fin):
        raise WSError("control frame too large or fragmented")
    head = bytearray([(0x80 if fin else 0) | (opcode & 0x0F)])
    mbit = 0x80 if mask else 0
    n = len(payload)
    if n < 126:
        head.append(mbit | n)
    elif n < 1 << 16:
        head.append(mbit | 126)
        head += struct.pack("!H", n)
    else:
        head.append(mbit | 127)
        head += struct.pack("!Q", n)
    if mask:
        mask_key = mask_key if mask_key is not None else os.urandom(4)
        if len(mask_key) != 4:
            raise WSError("mask key must be 4 bytes")
        head += mask_key
        payload = apply_mask(mask_key, payload)
    return bytes(head) + payload


def decode_frame(buf):
    if len(buf) < 2:
        return None
    b0, b1 = buf[0], buf[1]
    if b0 & 0x70:
        raise WSError("reserved bits set")
    fin = bool(b0 & 0x80)
    opcode = b0 & 0x0F
    masked = bool(b1 & 0x80)
    n = b1 & 0x7F
    pos = 2
    if n == 126:
        if len(buf) < pos + 2:
            return None
        n = struct.unpack_from("!H", buf, pos)[0]
        pos += 2
    elif n == 127:
        if len(buf) < pos + 8:
            return None
        n = struct.unpack_from("!Q", buf, pos)[0]
        if n >> 63:
            raise WSError("invalid length")
        pos += 8
    mask_key = None
    if masked:
        if len(buf) < pos + 4:
            return None
        mask_key = bytes(buf[pos:pos + 4])
        pos += 4
    if len(buf) < pos + n:
        return None
    payload = bytes(buf[pos:pos + n])
    if masked:
        payload = apply_mask(mask_key, payload)
    if opcode >= OP_CLOSE and (n > MAX_CONTROL or not fin):
        raise WSError("invalid control frame")
    return (fin, opcode, payload, masked), pos + n


def close_payload(code=1000, reason=""):
    if code is None:
        return b""
    return struct.pack("!H", code) + reason.encode("utf-8")[:MAX_CONTROL - 2]


def parse_close(payload):
    if len(payload) < 2:
        return None, ""
    return struct.unpack("!H", payload[:2])[0], payload[2:].decode("utf-8", "replace")


class WSClient:
    def __init__(self, url, headers=None, timeout=10.0, ssl_context=None, subprotocols=None,
                 max_message=16 * 1024 * 1024, connect_fn=None):
        self.url = url
        self.headers = dict(headers or {})
        self.timeout = timeout
        self.ssl_context = ssl_context
        self.subprotocols = list(subprotocols or [])
        self.max_message = max_message
        self.connect_fn = connect_fn or socket.create_connection
        self.sock = None
        self.subprotocol = None
        self.closed = True
        self._buf = bytearray()
        self._send_lock = threading.Lock()
        self._close_sent = False

    def _target(self):
        u = urllib.parse.urlsplit(self.url)
        if u.scheme not in ("ws", "wss"):
            raise WSError(f"unsupported scheme: {u.scheme}")
        secure = u.scheme == "wss"
        host = u.hostname or ""
        port = u.port or (443 if secure else 80)
        path = (u.path or "/") + (f"?{u.query}" if u.query else "")
        default = 443 if secure else 80
        hosthdr = f"[{host}]" if ":" in host else host
        if port != default:
            hosthdr += f":{port}"
        return secure, host, port, path, hosthdr

    def connect(self):
        secure, host, port, path, hosthdr = self._target()
        sock = self.connect_fn((host, port), self.timeout)
        try:
            if secure:
                ctx = self.ssl_context or ssl.create_default_context()
                sock = ctx.wrap_socket(sock, server_hostname=host)
            sock.settimeout(self.timeout)
            self.sock = sock
            self._buf = bytearray()
            self._handshake(path, hosthdr)
        except BaseException:
            try:
                sock.close()
            except OSError:
                pass
            self.sock = None
            raise
        self.closed = False
        self._close_sent = False
        return self

    def _handshake(self, path, hosthdr):
        key = new_key()
        lines = [f"GET {path} HTTP/1.1", f"Host: {hosthdr}", "Upgrade: websocket", "Connection: Upgrade",
                 f"Sec-WebSocket-Key: {key}", "Sec-WebSocket-Version: 13"]
        if self.subprotocols:
            lines.append("Sec-WebSocket-Protocol: " + ", ".join(self.subprotocols))
        for k, v in self.headers.items():
            lines.append(f"{k}: {v}")
        self.sock.sendall(("\r\n".join(lines) + "\r\n\r\n").encode("latin-1"))
        while b"\r\n\r\n" not in self._buf:
            if len(self._buf) > 65536:
                raise WSError("handshake response too large")
            self._fill()
        end = self._buf.index(b"\r\n\r\n")
        raw = bytes(self._buf[:end]).decode("latin-1")
        del self._buf[:end + 4]
        status, *hdr_lines = raw.split("\r\n")
        parts = status.split(" ", 2)
        if len(parts) < 2 or parts[1] != "101":
            raise WSError(f"handshake failed: {status}")
        hdrs = {}
        for line in hdr_lines:
            k, _, v = line.partition(":")
            hdrs[k.strip().lower()] = v.strip()
        if hdrs.get("upgrade", "").lower() != "websocket":
            raise WSError("missing upgrade header")
        if "upgrade" not in [t.strip().lower() for t in hdrs.get("connection", "").split(",")]:
            raise WSError("missing connection header")
        if hdrs.get("sec-websocket-accept") != accept_key(key):
            raise WSError("bad Sec-WebSocket-Accept")
        proto = hdrs.get("sec-websocket-protocol")
        if proto and proto not in self.subprotocols:
            raise WSError(f"unexpected subprotocol: {proto}")
        self.subprotocol = proto

    def _fill(self):
        chunk = self.sock.recv(65536)
        if not chunk:
            raise WSClosed(1006, "connection lost")
        self._buf += chunk

    def _send_frame(self, opcode, payload=b"", fin=True):
        if self.sock is None:
            raise WSClosed(1006, "not connected")
        data = encode_frame(opcode, payload, fin=fin, mask=True)
        with self._send_lock:
            self.sock.sendall(data)

    def send_text(self, text):
        self._send_frame(OP_TEXT, text.encode("utf-8"))

    def send_binary(self, data):
        self._send_frame(OP_BINARY, bytes(data))

    def ping(self, data=b""):
        self._send_frame(OP_PING, data)

    def pong(self, data=b""):
        self._send_frame(OP_PONG, data)

    def close(self, code=1000, reason="", wait=True):
        if self.sock is None:
            return
        try:
            if not self._close_sent:
                self._close_sent = True
                self._send_frame(OP_CLOSE, close_payload(code, reason))
            if wait:
                deadline = time.monotonic() + self.timeout
                while time.monotonic() < deadline:
                    frame = self._read_frame()
                    if frame[1] == OP_CLOSE:
                        break
        except (OSError, WSError):
            pass
        finally:
            self._shutdown()

    def _shutdown(self):
        self.closed = True
        sock, self.sock = self.sock, None
        if sock is not None:
            try:
                sock.close()
            except OSError:
                pass

    def _read_frame(self):
        while True:
            res = decode_frame(self._buf)
            if res is not None:
                frame, used = res
                del self._buf[:used]
                if frame[3]:
                    raise WSError("server frames must not be masked")
                return frame
            self._fill()

    def recv(self):
        parts = []
        msg_op = None
        size = 0
        while True:
            try:
                fin, opcode, payload, _ = self._read_frame()
            except WSError as e:
                if not isinstance(e, WSClosed):
                    self._fail(1002, str(e))
                else:
                    self._shutdown()
                raise
            if opcode == OP_PING:
                self.pong(payload)
                continue
            if opcode == OP_PONG:
                continue
            if opcode == OP_CLOSE:
                code, reason = parse_close(payload)
                if not self._close_sent:
                    self._close_sent = True
                    try:
                        self._send_frame(OP_CLOSE, close_payload(code) if code else b"")
                    except OSError:
                        pass
                self._shutdown()
                raise WSClosed(code, reason)
            if opcode in (OP_TEXT, OP_BINARY):
                if msg_op is not None:
                    self._fail(1002, "new message before fragment end")
                msg_op = opcode
            elif opcode == OP_CONT:
                if msg_op is None:
                    self._fail(1002, "unexpected continuation")
            else:
                self._fail(1002, f"unknown opcode {opcode}")
            size += len(payload)
            if size > self.max_message:
                self._fail(1009, "message too big")
            parts.append(payload)
            if fin:
                data = b"".join(parts)
                if msg_op == OP_TEXT:
                    try:
                        return OP_TEXT, data.decode("utf-8")
                    except UnicodeDecodeError:
                        self._fail(1007, "invalid utf-8")
                return msg_op, data

    def _fail(self, code, reason):
        self.close(code, reason, wait=False)
        raise WSClosed(code, reason)

    def __enter__(self):
        if self.closed:
            self.connect()
        return self

    def __exit__(self, *exc):
        self.close()


def exponential_backoff(base=0.5, factor=2.0, cap=30.0):
    def delay(attempt):
        return min(cap, base * factor ** attempt)
    return delay


def full_jitter(rng=None):
    rng = rng or random.Random()

    def jitter(d):
        return rng.uniform(0, d)
    return jitter


class Reconnector:
    def __init__(self, factory, backoff=None, jitter=None, sleep=time.sleep, max_attempts=None,
                 retry_on=(OSError, WSError)):
        self.factory = factory
        self.backoff = backoff or exponential_backoff()
        self.jitter = jitter or full_jitter()
        self.sleep = sleep
        self.max_attempts = max_attempts
        self.retry_on = retry_on
        self.attempt = 0
        self._stop = threading.Event()

    def stop(self):
        self._stop.set()

    @property
    def stopped(self):
        return self._stop.is_set()

    def next_delay(self):
        d = self.jitter(self.backoff(self.attempt))
        self.attempt += 1
        return max(0.0, d)

    def connect(self):
        while not self._stop.is_set():
            client = self.factory()
            try:
                client.connect()
                self.attempt = 0
                return client
            except self.retry_on:
                if self.max_attempts is not None and self.attempt + 1 >= self.max_attempts:
                    raise
                self.sleep(self.next_delay())
        raise WSClosed(None, "stopped")

    def run(self, on_message, on_open=None):
        while not self._stop.is_set():
            client = self.connect()
            try:
                if on_open:
                    on_open(client)
                while not self._stop.is_set():
                    op, data = client.recv()
                    on_message(client, op, data)
            except self.retry_on:
                if self._stop.is_set():
                    break
                self.sleep(self.next_delay())
            finally:
                client.close(wait=False)
