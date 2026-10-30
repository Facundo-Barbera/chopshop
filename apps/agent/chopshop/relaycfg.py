import argparse
import os
import re
import sys

from . import settings

TOKEN_RE = re.compile(r"^cr1_[A-Za-z0-9_-]{43}$")


class RelayCfgError(Exception):
    pass


def token_path():
    base = os.environ.get("XDG_CONFIG_HOME") or os.path.expanduser("~/.config")
    return os.path.join(base, "chopshop", "relay", "token")


def relay_url():
    try:
        return str(settings.section("relay").get("url") or "")
    except settings.SettingsError as e:
        raise RelayCfgError(str(e))


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
    p = token_path()
    os.makedirs(os.path.dirname(p), mode=0o700, exist_ok=True)
    tmp = p + ".tmp"
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w", encoding="utf-8") as f:
        f.write(token + "\n")
    os.chmod(tmp, 0o600)
    os.replace(tmp, p)
    return p


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


def cmd_status(a, out, err):
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


def build():
    p = argparse.ArgumentParser(prog="chopshop relay", description="Credencial cr1_ del relay en esta máquina (el token nunca se imprime)")
    sp = p.add_subparsers(dest="action", required=True)
    x = sp.add_parser("pair", help="guarda un token cr1_ en ~/.config/chopshop/relay/token (0600)")
    x.add_argument("--stdin", action="store_true", help="lee el token de la entrada estándar")
    x.add_argument("--token-file", help="archivo con el token (primera línea)")
    x.set_defaults(f=cmd_pair)
    x = sp.add_parser("status", help="URL del relay y token enmascarado"); x.set_defaults(f=cmd_status)
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
