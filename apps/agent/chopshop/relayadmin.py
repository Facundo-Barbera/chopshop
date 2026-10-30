import argparse
import json
import os
import re
import sys
import urllib.error
import urllib.parse
import urllib.request

from . import __version__

DEFAULT_API = "https://api.chopshop.novarix.online"
USER_AGENT = "chopshop-cli/" + __version__
EMAIL_RE = re.compile(r"^[^@\s]+@[^@\s]+\.[^@\s]+$")
LOOPBACK = ("127.0.0.1", "localhost", "::1")
EXIT_OK, EXIT_ERROR, EXIT_CONFLICT = 0, 1, 2


class AdminError(Exception):
    def __init__(self, message, code=EXIT_ERROR):
        super().__init__(message)
        self.code = code


class _Parser(argparse.ArgumentParser):
    def error(self, message):
        if message.startswith("unrecognized arguments"):
            message = "argumentos no reconocidos (el secret de operador solo por --token-file o --stdin)"
        raise AdminError(message)


class _NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


def api_base(url):
    url = (url or DEFAULT_API).strip().rstrip("/")
    u = urllib.parse.urlsplit(url)
    if u.scheme == "https" and u.hostname:
        return url
    if u.scheme == "http" and u.hostname in LOOPBACK:
        return url
    raise AdminError("--api debe ser https:// (http:// solo en loopback)")


def read_secret(a, stdin, err):
    if a.stdin == bool(a.token_file):
        raise AdminError("usa exactamente una fuente para el secret de operador: --stdin o --token-file F")
    if a.stdin:
        raw = stdin.readline()
    else:
        f = os.path.expanduser(a.token_file)
        if not os.path.isfile(f):
            raise AdminError("no existe el archivo indicado en --token-file")
        if os.stat(f).st_mode & 0o077:
            print("aviso: el archivo de --token-file es legible por otros; haz chmod 600", file=err)
        with open(f, encoding="utf-8") as fh:
            raw = fh.readline()
    secret = raw.strip()
    if not secret:
        raise AdminError("el secret de operador está vacío")
    if any(c.isspace() or not c.isprintable() for c in secret):
        raise AdminError("el secret de operador tiene caracteres no válidos")
    return secret


def post(base, path, secret, body, timeout=30):
    req = urllib.request.Request(base + path, data=json.dumps(body).encode("utf-8"), method="POST", headers={
        "Authorization": "Bearer " + secret,
        "Content-Type": "application/json",
        "Accept": "application/json",
        "User-Agent": USER_AGENT,
    })
    opener = urllib.request.build_opener(_NoRedirect)
    try:
        with opener.open(req, timeout=timeout) as r:
            status, raw = r.status, r.read()
    except urllib.error.HTTPError as e:
        status, raw = e.code, e.read()
    except (urllib.error.URLError, OSError) as e:
        raise AdminError("no se pudo contactar con la API %s: %s" % (base, getattr(e, "reason", e)))
    try:
        data = json.loads(raw.decode("utf-8")) if raw else {}
    except ValueError:
        data = {}
    if not isinstance(data, dict):
        data = {}
    if 200 <= status < 300:
        return data
    code, msg = str(data.get("code") or "error"), str(data.get("message") or "")
    text = "HTTP %d %s%s" % (status, code, (": " + msg) if msg else "")
    if status == 429 and data.get("retry_after_s") is not None:
        text += " (reintenta en %s s)" % data.get("retry_after_s")
    raise AdminError(text, EXIT_CONFLICT if status == 409 else EXIT_ERROR)


def show(data, out, what):
    link = data.get("link")
    if not isinstance(link, str) or not link:
        raise AdminError("respuesta inesperada de la API: falta link")
    inv = data.get("invitation") if isinstance(data.get("invitation"), dict) else {}
    print("%s para %s (caduca %s):" % (what, inv.get("email") or "el dueño", inv.get("expires_at") or "?"), file=out)
    print("", file=out)
    print("  " + link, file=out)
    print("", file=out)
    print("Este enlace se muestra UNA sola vez y no se puede recuperar: guárdalo fuera de línea o ábrelo ya.", file=out)
    code = data.get("recovery_code")
    if isinstance(code, str) and code:
        print("", file=out)
        print("Código de recuperación (se muestra UNA sola vez; guárdalo fuera de línea):", file=out)
        print("  " + code, file=out)
    else:
        print("Al aceptarlo verás el código de recuperación UNA sola vez: guárdalo fuera de línea.", file=out)


def cmd_bootstrap(a, stdin, out, err):
    email = a.email.strip()
    if len(email) > 254 or not EMAIL_RE.match(email):
        raise AdminError("correo inválido")
    base = api_base(a.api)
    secret = read_secret(a, stdin, err)
    try:
        data = post(base, "/v1/operator/bootstrap", secret, {"email": email})
    except AdminError as e:
        if e.code == EXIT_CONFLICT:
            raise AdminError("ya existe un dueño; para recuperarlo usa chopshop relay admin recover (%s)" % e, EXIT_CONFLICT)
        raise
    show(data, out, "Invitación del dueño")
    return EXIT_OK


def cmd_recover(a, stdin, out, err):
    base = api_base(a.api)
    secret = read_secret(a, stdin, err)
    try:
        data = post(base, "/v1/operator/recover", secret, {})
    except AdminError as e:
        if e.code == EXIT_CONFLICT:
            raise AdminError("no hay dueño; créalo con chopshop relay admin bootstrap (%s)" % e, EXIT_CONFLICT)
        raise
    show(data, out, "Invitación de recuperación del dueño")
    return EXIT_OK


def _source(x):
    x.add_argument("--token-file", help="archivo con el secret de operador (primera línea; chmod 600)")
    x.add_argument("--stdin", action="store_true", help="lee el secret de operador de la entrada estándar")
    x.add_argument("--api", help="base de la API (por defecto %s)" % DEFAULT_API)


def build():
    p = _Parser(prog="chopshop relay admin", allow_abbrev=False, description="Operador del backend: bootstrap y recuperación del dueño (el secret nunca va en argv ni se imprime)")
    sp = p.add_subparsers(dest="action", required=True)
    x = sp.add_parser("bootstrap", allow_abbrev=False, help="crea la invitación del dueño (una sola vez)")
    x.add_argument("--email", required=True, help="correo del dueño")
    _source(x)
    x.set_defaults(f=cmd_bootstrap)
    x = sp.add_parser("recover", allow_abbrev=False, help="crea una invitación owner_reset para el dueño (caduca en 1 h)")
    _source(x)
    x.set_defaults(f=cmd_recover)
    return p


def main(argv, stdin=None, stdout=None, stderr=None):
    inp, out, err = stdin or sys.stdin, stdout or sys.stdout, stderr or sys.stderr
    try:
        a = build().parse_args(argv)
        return a.f(a, inp, out, err)
    except AdminError as e:
        print("error: %s" % e, file=err)
        return e.code
