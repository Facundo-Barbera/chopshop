"""Cliente nativo (stdlib) del MCP HTTP de T3: JSON-RPC 2.0 por POST a <origin>/mcp.

Reemplaza al cliente node anterior y al transporte remoto viejo. Autenticación: flujo
OAuth MCP de T3 (registro de cliente público + PKCE S256) aprobado con un código de pairing de un solo
uso emitido EN LOCAL por `t3 auth pairing create` y revocado siempre después. El resultado es una sesión
"MCP client" normal de T3, cacheada 0600 en <CHOPSHOP_HOME>/t3-credential.json.
El token nunca se imprime, ni se registra, ni aparece en mensajes de error.

Todo lo externo es inyectable: `http(method, url, headers, body, timeout) -> (status, headers, text)`
(cabeceras en minúsculas), `run(argv, timeout) -> objeto con returncode/stdout/stderr` y `clock() -> s`."""
import base64
import hashlib
import json
import logging
import os
import secrets
import subprocess
import threading
import time
import urllib.error
import urllib.parse
import urllib.request

log = logging.getLogger("chopshop.t3mcp")

PROTOCOL = "2025-06-18"
REDIRECT = "http://127.0.0.1:1/chopshop-callback"
RUNTIME_FILE = "~/.t3/userdata/server-runtime.json"
MAX_MSG = 600
# acciones de t3_thread_organize permitidas: jamás archivar desde Chopshop
ORGANIZE_OK = ("settle", "unsettle")


class T3Error(Exception):
    pass


class _Unauthorized(Exception):
    pass


class _SessionGone(Exception):
    pass


class _NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *a, **k):
        return None


_opener = urllib.request.build_opener(_NoRedirect)


def _urllib_http(method, url, headers, body, timeout):
    """Transporte por defecto: devuelve (status, cabeceras en minúsculas, texto); errores HTTP no lanzan."""
    req = urllib.request.Request(url, data=body, headers=headers, method=method)
    try:
        with _opener.open(req, timeout=timeout) as r:
            return r.status, {k.lower(): v for k, v in r.headers.items()}, r.read().decode("utf-8", "replace")
    except urllib.error.HTTPError as e:
        hdrs = {k.lower(): v for k, v in (e.headers.items() if e.headers else [])}
        try:
            text = e.read().decode("utf-8", "replace")
        except Exception:
            text = ""
        return e.code, hdrs, text


def _subprocess_run(argv, timeout):
    return subprocess.run(argv, capture_output=True, text=True, stdin=subprocess.DEVNULL, timeout=timeout)


def _b64url(raw):
    return base64.urlsafe_b64encode(raw).rstrip(b"=").decode("ascii")


def _is_local(origin):
    host = (urllib.parse.urlsplit(origin).hostname or "").lower()
    return host in ("localhost", "::1") or host.startswith("127.")


def _default_credential_file():
    from . import home
    return os.path.join(home.home(), "t3-credential.json")


class Client:
    def __init__(self, origin=None, access="approval-required", credential_file=None, t3_bin="t3", timeout=90,
                 http=None, run=None, clock=None, runtime_file=RUNTIME_FILE):
        self._origin = origin
        self.access = access
        self.credential_file = credential_file
        self.t3_bin = os.path.expanduser(t3_bin)
        self.timeout = timeout
        self.runtime_file = runtime_file
        self._http = http or _urllib_http
        self._run = run or _subprocess_run
        self._clock = clock or time.time
        self._cred = None
        self._sid = None
        self._ready = False
        self._n = 0
        self._secrets = set()  # valores a tachar de cualquier mensaje (token, pairing, verifier, code)
        self._lock = threading.RLock()

    # ---- utilidades ----
    def _err(self, msg):
        msg = str(msg)
        for s in self._secrets:
            if s:
                msg = msg.replace(s, "***")
        if len(msg) > MAX_MSG:
            msg = msg[:MAX_MSG - 1] + "…"
        return T3Error(msg)

    def _secret(self, value):
        if isinstance(value, str) and value:
            self._secrets.add(value)
        return value

    @property
    def origin(self):
        if not self._origin:
            path = os.path.expanduser(self.runtime_file)
            try:
                with open(path, encoding="utf-8") as f:
                    origin = json.load(f).get("origin")
            except (OSError, ValueError, AttributeError) as e:
                raise self._err("no pude leer el origen de T3 de %s: %s" % (path, e))
            if not origin:
                raise self._err("%s no tiene campo 'origin'" % path)
            self._origin = origin
        return self._origin.rstrip("/")

    @property
    def endpoint(self):
        return urllib.parse.urljoin(self.origin + "/", "/mcp")

    def _cache_path(self):
        if not self.credential_file:
            self.credential_file = _default_credential_file()
        return os.path.expanduser(self.credential_file)

    def _now_ms(self):
        return self._clock() * 1000

    def _valid(self, cred):
        return (isinstance(cred, dict) and cred.get("token") and cred.get("origin") == self.origin
                and cred.get("access") == self.access and (cred.get("expiresAt") or 0) > self._now_ms())

    def _send(self, url, headers, body):
        try:
            return self._http("POST", url, headers, body, self.timeout)
        except T3Error as e:
            raise self._err(e)
        except Exception as e:  # red, timeouts, DNS…
            raise self._err("error de red con T3 (%s): %s" % (urllib.parse.urlsplit(url).path, e))

    # ---- credencial ----
    def _load_cache(self):
        path = self._cache_path()
        try:
            with open(path, encoding="utf-8") as f:
                cred = json.load(f)
        except (OSError, ValueError):
            return None
        if self._valid(cred):
            self._secret(cred["token"])
            return cred
        return None

    def _save_cache(self, cred):
        path = self._cache_path()
        d = os.path.dirname(path)
        if d:
            os.makedirs(d, mode=0o700, exist_ok=True)
        tmp = "%s.%d.tmp" % (path, os.getpid())
        fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        try:
            os.fchmod(fd, 0o600)
            with os.fdopen(fd, "w", encoding="utf-8") as f:
                json.dump(cred, f)
        except Exception:
            try:
                os.unlink(tmp)
            except OSError:
                pass
            raise
        os.replace(tmp, path)

    def _drop_cache(self):
        self._cred = None
        try:
            os.unlink(self._cache_path())
        except OSError:
            pass

    def _post_oauth(self, path, body, form=False):
        if form:
            headers, data = {"content-type": "application/x-www-form-urlencoded"}, urllib.parse.urlencode(body)
        else:
            headers, data = {"content-type": "application/json"}, json.dumps(body)
        status, _, text = self._send(self.origin + path, headers, data.encode("utf-8"))
        if not 200 <= status < 300:
            raise self._err("%s HTTP %s: %s" % (path, status, text[:200]))
        try:
            return json.loads(text)
        except ValueError:
            raise self._err("%s devolvió algo que no es JSON" % path)

    def _t3(self, args):
        """Ejecuta el CLI `t3` local; devuelve stdout o lanza OSError/RuntimeError."""
        r = self._run([self.t3_bin] + args, 30)
        if r.returncode != 0:
            raise RuntimeError(("%s" % (r.stderr or r.stdout or "")).strip()[:200] or "código %s" % r.returncode)
        return r.stdout

    def _pairing(self):
        args = ["auth", "pairing", "create", "--json", "--ttl", "2m", "--label", "chopshop",
                "--scope", "orchestration:read", "--scope", "orchestration:operate"]
        if self.access == "full-access":
            args += ["--scope", "settings:write", "--scope", "source-control:write"]
        try:
            out = self._t3(args)
            pairing = json.loads(out)
            if not (isinstance(pairing, dict) and pairing.get("id") and pairing.get("credential")):
                raise ValueError("salida inesperada de `t3 auth pairing create`")
        except (OSError, RuntimeError, ValueError, subprocess.SubprocessError) as e:
            if not _is_local(self.origin):
                raise self._err("T3 en %s es remoto y no hay credencial válida en caché ni `t3` local utilizable "
                                "para emitir un código de pairing (%s); inicia sesión una vez en la máquina de T3 "
                                "o copia allí la credencial" % (self.origin, e))
            raise self._err("no pude crear el código de pairing con `%s auth pairing create`: %s" % (self.t3_bin, e))
        self._secret(pairing["credential"])
        return pairing

    def _sign_in(self):
        log.info("iniciando sesión MCP en %s (acceso %s)", self.origin, self.access)
        client = self._post_oauth("/oauth/mcp/register", {"client_name": "chopshop", "redirect_uris": [REDIRECT]})
        client_id = client.get("client_id")
        if not client_id:
            raise self._err("/oauth/mcp/register no devolvió client_id")
        verifier = self._secret(_b64url(secrets.token_bytes(48)))
        authorization = {
            "response_type": "code", "client_id": client_id, "redirect_uri": REDIRECT,
            "code_challenge": _b64url(hashlib.sha256(verifier.encode("ascii")).digest()),
            "code_challenge_method": "S256", "state": secrets.token_hex(8), "resource": self.endpoint,
        }
        pairing = self._pairing()
        try:
            dec = self._post_oauth("/oauth/mcp/decision", {
                "authorization": authorization,
                "decision": {"_tag": "pairing-code", "access": self.access, "code": pairing["credential"]}})
        finally:
            try:
                self._t3(["auth", "pairing", "revoke", str(pairing["id"])])
            except Exception as e:
                log.warning("no pude revocar el código de pairing %s: %s", pairing["id"], type(e).__name__)
        q = urllib.parse.parse_qs(urllib.parse.urlsplit(str(dec.get("redirectTo") or "")).query)
        code = self._secret((q.get("code") or [None])[0])
        if not code:
            raise self._err("aprobación rechazada: %s" % ((q.get("error") or ["sin código"])[0]))
        tok = self._post_oauth("/oauth/mcp/token", {
            "grant_type": "authorization_code", "code": code, "redirect_uri": REDIRECT,
            "client_id": client_id, "code_verifier": verifier, "resource": self.endpoint}, form=True)
        token = self._secret(tok.get("access_token"))
        if not token:
            raise self._err("/oauth/mcp/token no devolvió access_token")
        try:
            expires_in = float(tok.get("expires_in") or 0)
        except (TypeError, ValueError):
            expires_in = 0
        # margen de 1 h como el cliente anterior; si T3 no da caducidad, se reintenta ante 401
        ttl = expires_in - 3600 if expires_in > 3600 else max(expires_in, 0) or 24 * 3600
        cred = {"origin": self.origin, "access": self.access, "token": token,
                "expiresAt": int(self._now_ms() + ttl * 1000)}
        try:
            self._save_cache(cred)
        except OSError as e:
            log.warning("no pude guardar la credencial de T3 en caché: %s", e)
        log.info("sesión MCP de T3 lista")
        return cred

    def _credential(self):
        if not self._valid(self._cred):
            self._cred = self._load_cache() or self._sign_in()
        return self._cred

    # ---- JSON-RPC ----
    def _rpc(self, method, params, notify=False):
        cred = self._credential()
        headers = {"content-type": "application/json", "accept": "application/json, text/event-stream",
                   "authorization": "Bearer " + cred["token"], "mcp-protocol-version": PROTOCOL}
        if self._sid:
            headers["mcp-session-id"] = self._sid
        body = {"jsonrpc": "2.0", "method": method, "params": params}
        if not notify:
            self._n += 1
            body["id"] = self._n
        status, hdrs, text = self._send(self.endpoint, headers, json.dumps(body).encode("utf-8"))
        hdrs = {k.lower(): v for k, v in (hdrs or {}).items()}
        if hdrs.get("mcp-session-id"):
            self._sid = hdrs["mcp-session-id"]
        if status == 401:
            raise _Unauthorized()
        if status == 404 and self._sid and method != "initialize":
            raise _SessionGone()
        if not 200 <= status < 300:
            raise self._err("MCP %s HTTP %s: %s" % (method, status, (text or "")[:300]))
        if notify:
            return None
        msg = None
        if "text/event-stream" in hdrs.get("content-type", ""):
            for data in _sse_events(text or ""):
                try:
                    m = json.loads(data)
                except ValueError:
                    continue
                if isinstance(m, dict) and m.get("id") == body["id"]:
                    msg = m
        else:
            try:
                msg = json.loads(text or "")
            except ValueError:
                raise self._err("respuesta MCP de %s no es JSON" % method)
        if not isinstance(msg, dict):
            raise self._err("respuesta MCP vacía para %s" % method)
        if msg.get("error") is not None:
            raise self._err("MCP %s: %s" % (method, json.dumps(msg["error"], ensure_ascii=False)))
        return msg.get("result")

    def _ensure_session(self):
        if self._ready:
            return
        self._rpc("initialize", {"protocolVersion": PROTOCOL, "capabilities": {},
                                 "clientInfo": {"name": "chopshop", "version": "1"}})
        self._rpc("notifications/initialized", {}, notify=True)
        self._ready = True

    def _reset_session(self):
        self._sid = None
        self._ready = False

    def _request(self, method, params):
        with self._lock:
            for attempt in (0, 1):
                try:
                    self._ensure_session()
                    return self._rpc(method, params)
                except _Unauthorized:
                    if attempt:
                        raise self._err("T3 rechazó la credencial MCP (401) incluso tras renovarla")
                    log.info("T3 respondió 401: renuevo la credencial y reintento una vez")
                    self._drop_cache()
                    self._reset_session()
                except _SessionGone:
                    if attempt:
                        raise self._err("T3 no reconoce la sesión MCP (404) incluso tras reabrirla")
                    log.info("sesión MCP caducada: la reabro")
                    self._reset_session()

    # ---- API pública ----
    def list_tools(self):
        res = self._request("tools/list", {}) or {}
        return res.get("tools", []) if isinstance(res, dict) else []

    def call(self, tool, args=None):
        args = args or {}
        if tool == "t3_thread_organize" and args.get("action") not in ORGANIZE_OK:
            raise T3Error("t3_thread_organize con action=%r no permitido: Chopshop solo hace settle/unsettle"
                          % (args.get("action"),))
        res = self._request("tools/call", {"name": tool, "arguments": args})
        if not isinstance(res, dict):
            raise self._err("%s: resultado MCP inesperado" % tool)
        data = res.get("structuredContent")
        if data is None:
            data = res.get("content")
        if res.get("isError"):
            raise self._err("%s falló: %s" % (tool, _text_of(data)))
        # errores de herramienta MCP que llegan como content=[{type:text,text:'{"_tag":...Failure...}'}]
        if isinstance(data, list) and data and isinstance(data[0], dict) and "_tag" in str(data[0].get("text", ""))[:20]:
            raise self._err("%s: %s" % (tool, data[0]["text"]))
        return data


def _sse_events(text):
    """Devuelve el payload (líneas data: unidas) de cada evento SSE."""
    buf = []
    for line in text.splitlines():
        if line.startswith("data:"):
            buf.append(line[5:].lstrip(" "))
        elif not line.strip() and buf:
            yield "\n".join(buf)
            buf = []
    if buf:
        yield "\n".join(buf)


def _text_of(data):
    if isinstance(data, list):
        parts = [str(c.get("text", "")) for c in data if isinstance(c, dict) and c.get("text")]
        if parts:
            return " ".join(parts)
    return json.dumps(data, ensure_ascii=False) if not isinstance(data, str) else data
