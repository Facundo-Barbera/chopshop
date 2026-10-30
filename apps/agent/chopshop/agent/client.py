import json
import os
import urllib.error
import urllib.parse
import urllib.request

from .. import settings

URL_ENV = "CHOPSHOP_AGENT_URL"


class AgentError(Exception):
    def __init__(self, message, status=None):
        super().__init__(message)
        self.status = status


def load_cfg():
    try:
        from . import config
        return config.load()
    except settings.SettingsError:
        cfg = dict(settings.DEFAULTS["agent"])
        cfg["token_file"] = os.path.expanduser(cfg["token_file"])
        return cfg


def resolve_url(cfg=None, environ=None):
    env = os.environ if environ is None else environ
    url = (env.get(URL_ENV) or "").strip()
    if url:
        return url.rstrip("/")
    cfg = cfg if cfg is not None else load_cfg()
    return "http://127.0.0.1:%d" % int(cfg.get("port") or settings.DEFAULTS["agent"]["port"])


def read_token(token_file):
    if not token_file:
        return None
    try:
        with open(os.path.expanduser(token_file), encoding="utf-8") as f:
            return f.read().strip() or None
    except OSError:
        return None


class AgentClient:
    def __init__(self, url=None, token_file=None, timeout=10, cfg=None, environ=None):
        if url is None or token_file is None:
            cfg = cfg if cfg is not None else load_cfg()
        self.url = url.rstrip("/") if url else resolve_url(cfg, environ)
        self.token = read_token(token_file if token_file is not None else cfg.get("token_file"))
        self.timeout = timeout
        self._opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))

    def _request(self, method, path, body=None, params=None, timeout=None):
        url = self.url + path
        if params:
            url += "?" + urllib.parse.urlencode({k: v for k, v in params.items() if v is not None})
        data = None
        headers = {"Accept": "application/json"}
        if body is not None:
            data = json.dumps(body).encode("utf-8")
            headers["Content-Type"] = "application/json"
        if self.token:
            headers["Authorization"] = "Bearer " + self.token
        req = urllib.request.Request(url, data=data, headers=headers, method=method)
        try:
            with self._opener.open(req, timeout=timeout or self.timeout) as resp:
                raw = resp.read()
        except urllib.error.HTTPError as e:
            raise AgentError(_error_message(e), status=e.code)
        except (urllib.error.URLError, OSError) as e:
            raise AgentError("agente no disponible en %s: %s" % (self.url, getattr(e, "reason", e)))
        try:
            return json.loads(raw.decode("utf-8")) if raw else {}
        except ValueError:
            raise AgentError("respuesta no JSON del agente en %s" % path)

    def get(self, path, params=None, timeout=None):
        return self._request("GET", path, params=params, timeout=timeout)

    def post(self, path, body=None, timeout=None):
        return self._request("POST", path, body=body if body is not None else {}, timeout=timeout)


def _error_message(e):
    try:
        msg = json.loads(e.read().decode("utf-8")).get("error")
    except (ValueError, AttributeError, OSError):
        msg = None
    finally:
        e.close()
    return "HTTP %d: %s" % (e.code, msg or e.reason)
