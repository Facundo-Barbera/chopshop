import argparse
import json
import os
import re
import sys
import time
from urllib.parse import urlsplit

from . import settings

TOKEN_RE = re.compile(r"^cr1_[A-Za-z0-9_-]{43}$")
MACHINE_CRED_RE = re.compile(r"^cm1_[A-Za-z0-9_-]{43}$")
UUID_RE = re.compile(r"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$")
LOCAL_ID_RE = re.compile(r"^[A-Za-z0-9_.:-]{1,128}$")
LOOPBACK = ("127.0.0.1", "localhost", "::1")


class RelayCfgError(Exception):
    pass


def _dir():
    base = os.environ.get("XDG_CONFIG_HOME") or os.path.expanduser("~/.config")
    return os.path.join(base, "chopshop", "relay")


def token_path():
    return os.path.join(_dir(), "token")


def machine_path():
    return os.path.join(_dir(), "machine.json")


def relay_url():
    try:
        return str(settings.section("relay").get("url") or "")
    except settings.SettingsError as e:
        raise RelayCfgError(str(e))


def ws_url(url):
    url = (url or "").strip()
    if not url:
        return ""
    if url.startswith(("wss://", "ws://")) or url.rstrip("/").endswith("/v1/connect"):
        return url
    if url.startswith("https://"):
        url = "wss://" + url[len("https://"):]
    elif url.startswith("http://"):
        url = "ws://" + url[len("http://"):]
    else:
        raise RelayCfgError("[relay] url debe empezar por https:// (o wss://…/v1/connect)")
    return url.rstrip("/") + "/v1/connect"


def api_url():
    try:
        m = read_machine()
    except RelayCfgError:
        m = None
    return m["api_url"] if m else relay_url()


def check_api_url(url):
    if not isinstance(url, str):
        raise RelayCfgError("api_url inválida")
    u = urlsplit(url)
    if u.scheme == "https" and u.hostname:
        return url.rstrip("/")
    if u.scheme == "http" and u.hostname in LOOPBACK:
        return url.rstrip("/")
    raise RelayCfgError("api_url inválida: se esperaba https://host (http solo en loopback)")


def validate_machine(d):
    if not isinstance(d, dict):
        raise RelayCfgError("machine.json inválido: se esperaba un objeto")
    if d.get("v") != 1:
        raise RelayCfgError("machine.json inválido: versión no soportada")
    api = check_api_url(d.get("api_url"))
    mid = d.get("machine_id")
    if not isinstance(mid, str) or not UUID_RE.match(mid):
        raise RelayCfgError("machine_id inválido: se esperaba un uuid")
    lid = d.get("local_machine_id")
    if not isinstance(lid, str) or not LOCAL_ID_RE.match(lid):
        raise RelayCfgError("local_machine_id inválido")
    cred = d.get("credential")
    if not isinstance(cred, str) or not MACHINE_CRED_RE.match(cred):
        raise RelayCfgError("credencial inválida: se esperaba cm1_ seguido de 43 caracteres base64url")
    linked = d.get("linked_at")
    if not isinstance(linked, str) or not linked:
        raise RelayCfgError("linked_at inválido")
    return {"v": 1, "api_url": api, "machine_id": mid, "local_machine_id": lid, "credential": cred, "linked_at": linked}


def read_machine():
    try:
        with open(machine_path(), encoding="utf-8") as f:
            raw = f.read()
    except FileNotFoundError:
        return None
    try:
        d = json.loads(raw)
    except ValueError:
        raise RelayCfgError("machine.json inválido: no es JSON")
    return validate_machine(d)


def _write_private(p, text):
    d = os.path.dirname(p)
    os.makedirs(d, mode=0o700, exist_ok=True)
    os.chmod(d, 0o700)
    tmp = p + ".tmp"
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w", encoding="utf-8") as f:
        f.write(text)
    os.chmod(tmp, 0o600)
    os.replace(tmp, p)
    return p


def write_machine(d):
    d = dict(d, v=1)
    d.setdefault("linked_at", time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()))
    m = validate_machine(d)
    return _write_private(machine_path(), json.dumps(m, ensure_ascii=False, indent=2) + "\n")


def remove_machine():
    try:
        os.remove(machine_path())
        return True
    except FileNotFoundError:
        return False


def mask(token):
    return "%s…%s" % (token[:4], token[-4:])


def read_token():
    p = token_path()
    try:
        with open(p, encoding="utf-8") as f:
            return f.read().strip()
    except FileNotFoundError:
        return None


def write_token(token):
    token = token.strip()
    if not TOKEN_RE.match(token):
        raise RelayCfgError("token inválido: se esperaba cr1_ seguido de 43 caracteres base64url")
    return _write_private(token_path(), token + "\n")


def remove_token():
    try:
        os.remove(token_path())
        return True
    except FileNotFoundError:
        return False


def cmd_pair(a, out, err):
    if a.stdin == bool(a.token_file):
        raise RelayCfgError("usa exactamente una fuente: --stdin o --token-file F")
    if a.stdin:
        raw = sys.stdin.readline()
    else:
        f = os.path.expanduser(a.token_file)
        if not os.path.isfile(f):
            raise RelayCfgError("no existe el archivo de token: %s" % a.token_file)
        if os.stat(f).st_mode & 0o077:
            print("aviso: %s es legible por otros; haz chmod 600 (o bórralo ya emparejado)" % a.token_file, file=err)
        with open(f, encoding="utf-8") as fh:
            raw = fh.readline()
    p = write_token(raw)
    print("emparejado: token %s guardado en %s (0600)" % (mask(raw.strip()), p), file=out)
    if not relay_url():
        print("aviso: falta [relay] url en %s" % settings.path(), file=err)
    return 0


def cmd_link(a, out, err):
    if not a.stdin:
        raise RelayCfgError("usa --stdin con el JSON de enlace {api_url, machine_id, local_machine_id, credential}")
    try:
        d = json.loads(sys.stdin.read())
    except ValueError:
        raise RelayCfgError("la entrada no es JSON válido")
    if not isinstance(d, dict):
        raise RelayCfgError("la entrada debe ser un objeto JSON")
    d = {k: d.get(k) for k in ("api_url", "machine_id", "local_machine_id", "credential")}
    if a.api:
        d["api_url"] = a.api
    if not d.get("api_url"):
        d["api_url"] = relay_url()
    p = write_machine(d)
    m = read_machine()
    print("enlazada: máquina %s con credencial %s guardada en %s (0600)" % (m["machine_id"], mask(m["credential"]), p), file=out)
    return 0


def _status_machine(out, err):
    try:
        m = read_machine()
    except RelayCfgError as e:
        print("máquina: %s (%s)" % (e, machine_path()), file=out)
        return 1
    mode = os.stat(machine_path()).st_mode & 0o777
    dmode = os.stat(_dir()).st_mode & 0o777
    print("api: %s" % m["api_url"], file=out)
    print("websocket: %s" % ws_url(m["api_url"]), file=out)
    print("máquina: %s (local %s, enlazada %s)" % (m["machine_id"], m["local_machine_id"], m["linked_at"]), file=out)
    print("credencial: %s en %s (permisos %o, directorio %o)" % (mask(m["credential"]), machine_path(), mode, dmode), file=out)
    if mode & 0o077 or dmode & 0o077:
        print("aviso: la credencial es accesible por otros; haz chmod 600 %s y chmod 700 %s" % (machine_path(), _dir()), file=err)
    return 0


def cmd_status(a, out, err):
    if os.path.exists(machine_path()):
        return _status_machine(out, err)
    url = relay_url()
    tok = read_token()
    print("url: %s" % (url or "(sin configurar: [relay] url)"), file=out)
    if tok is None:
        print("token: no emparejado (%s)" % token_path(), file=out)
        return 1
    mode = os.stat(token_path()).st_mode & 0o777
    ok = bool(TOKEN_RE.match(tok))
    print("token: %s en %s (permisos %o)" % (mask(tok) if ok else "(formato inválido)", token_path(), mode), file=out)
    if mode & 0o077:
        print("aviso: el token es legible por otros; haz chmod 600 %s" % token_path(), file=err)
    return 0 if ok and url else 1


def cmd_unpair(a, out, err):
    if remove_token():
        print("desemparejado: token local borrado (revócalo en el relay con DELETE /v1/tokens/<token_id>)", file=out)
    else:
        print("no había token emparejado", file=out)
    return 0


def cmd_unlink(a, out, err):
    if remove_machine():
        print("desenlazada: machine.json borrado; revoca la máquina desde la app o la web admin", file=out)
    else:
        print("no había máquina enlazada", file=out)
    return 0


def build():
    p = argparse.ArgumentParser(prog="chopshop relay", description="Credenciales del relay en esta máquina (cm1_ en machine.json, cr1_ heredado; nunca se imprimen)")
    sp = p.add_subparsers(dest="action", required=True)
    x = sp.add_parser("pair", help="guarda un token cr1_ en ~/.config/chopshop/relay/token (0600)")
    x.add_argument("--stdin", action="store_true", help="lee el token de la entrada estándar")
    x.add_argument("--token-file", help="archivo con el token (primera línea)")
    x.set_defaults(f=cmd_pair)
    x = sp.add_parser("link", help="guarda machine.json (credencial cm1_, 0600) desde el JSON de enlace")
    x.add_argument("--stdin", action="store_true", help="lee el JSON de enlace de la entrada estándar")
    x.add_argument("--api", help="base de la API (manda sobre la del JSON y sobre [relay] url)")
    x.set_defaults(f=cmd_link)
    x = sp.add_parser("status", help="API, máquina y credencial enmascarada"); x.set_defaults(f=cmd_status)
    x = sp.add_parser("unlink", help="borra machine.json"); x.set_defaults(f=cmd_unlink)
    x = sp.add_parser("unpair", help="borra el token local"); x.set_defaults(f=cmd_unpair)
    return p


def main(argv, stdout=None, stderr=None):
    out, err = stdout or sys.stdout, stderr or sys.stderr
    a = build().parse_args(argv)
    try:
        return a.f(a, out, err)
    except RelayCfgError as e:
        print("error: %s" % e, file=err)
        return 1
