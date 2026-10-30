"""Emparejamiento único por dispositivo (docs/agent-api.md, «Emparejamiento»).

- `chopshop pair create` (CLI LOCAL, escribe directo en la DB del agente) genera un código de un solo uso (`K7QM-93XD`, 8 símbolos
  base32 de Crockford = 40 bits) con caducidad (10 min por defecto, máx. 1 h). Solo se guarda `sha256(sal + código)` en `pair_codes`.
  No hay ruta HTTP para crear códigos.
- `POST /pair {"code","device_name","device_id"}` canjea el código (`Pairing.redeem`) y devuelve una credencial `cs1_<43 car.>`
  (32 bytes aleatorios en base64url). En `devices` solo queda `sha256(credencial)`; la credencial se muestra una sola vez.
- Intentos fallidos: 5 por minuto por IP (429) y 20 por código vivo (cada fallo cuenta contra todos los códigos vivos; al llegar a 20
  el código queda invalidado). Comparaciones con `hmac.compare_digest`.
- `check(credencial)` -> id del dispositivo si existe y no está revocado (consulta la DB en cada llamada: revocar desde la CLI tiene
  efecto inmediato aunque el agente sea otro proceso). `last_seen_at`/`last_ip` se escriben como mucho una vez por minuto.
Nunca se registran ni se devuelven códigos, credenciales ni hashes (salvo la credencial recién emitida, al que canjea).
Las tablas se crean con `CREATE TABLE IF NOT EXISTS` (sin tocar `user_version`, que llevan las migraciones del bus de eventos)."""
import argparse
import base64
import hashlib
import hmac
import json
import os
import re
import secrets
import sys
import threading
import time
import uuid

from . import db

ALPHABET = "0123456789ABCDEFGHJKMNPQRSTVWXYZ"     # base32 de Crockford (sin I, L, O, U)
CODE_LEN = 8                                     # 8 x 5 bits = 40 bits
CRED_PREFIX = "cs1_"
DEFAULT_TTL = 600.0                              # s
MAX_TTL = 3600.0
IP_FAILS = 5                                     # fallos por IP ...
IP_WINDOW = 60.0                                 # ... en esta ventana (s)
CODE_FAILS = 20                                  # fallos que invalidan un código vivo
SEEN_EVERY = 60.0                                # s mínimos entre escrituras de last_seen_at por dispositivo
KEEP_USED = 7 * 86400.0                          # `prune` borra códigos usados/caducados más viejos que esto
_ID = re.compile(r"^[A-Za-z0-9_.:-]{1,128}$")
_CRED = re.compile(r"^cs1_[A-Za-z0-9_-]{43}$")

SCHEMA = """
CREATE TABLE IF NOT EXISTS pair_codes (
  id TEXT PRIMARY KEY, code_hash TEXT NOT NULL, salt TEXT NOT NULL, name TEXT, created_at REAL NOT NULL,
  expires_at REAL NOT NULL, used_at REAL, failures INTEGER NOT NULL DEFAULT 0, invalidated_at REAL, device_id TEXT);
CREATE TABLE IF NOT EXISTS devices (
  id TEXT PRIMARY KEY, name TEXT, cred_hash TEXT NOT NULL UNIQUE, created_at REAL NOT NULL, last_seen_at REAL,
  last_ip TEXT, revoked_at REAL);
"""


class PairError(Exception):
    """Fallo de emparejamiento con su código HTTP (401 inválido, 410 caducado/usado, 429 demasiados intentos, 400 petición)."""

    def __init__(self, status, message):
        super().__init__(message)
        self.status, self.message = status, message


def ensure_schema(conn):
    with db.tx():
        conn.executescript(SCHEMA)


def normalize(code):
    """Texto tecleado -> 8 símbolos canónicos o None (sin guiones/espacios; O->0, I/L->1; sin distinguir mayúsculas)."""
    if not isinstance(code, str):
        return None
    s = re.sub(r"[\s-]", "", code).upper().translate(str.maketrans("OIL", "011"))
    return s if len(s) == CODE_LEN and all(c in ALPHABET for c in s) else None


def _code_hash(salt, code):
    return hashlib.sha256((salt + ":" + code).encode("utf-8")).hexdigest()


def _cred_hash(cred):
    return hashlib.sha256(cred.encode("utf-8")).hexdigest()


def parse_ttl(text):
    """'10m' | '90s' | '1h' | '600' -> segundos (1 s .. MAX_TTL) o ValueError."""
    m = re.match(r"^\s*(\d+(?:\.\d+)?)\s*([smh]?)\s*$", str(text))
    if not m:
        raise ValueError("ttl inválido: usa 90s, 10m o 1h")
    v = float(m.group(1)) * {"": 1, "s": 1, "m": 60, "h": 3600}[m.group(2)]
    if not 1 <= v <= MAX_TTL:
        raise ValueError("ttl fuera de rango (1 s a 1 h)")
    return v


class Pairing:
    def __init__(self, conn, clock=time.time):
        self.conn, self.clock = conn, clock
        self._lock = threading.Lock()
        self._fails = {}                         # ip -> [ts de fallos recientes]
        self._seen = {}                          # device_id -> último ts escrito
        ensure_schema(conn)

    # -- códigos (solo CLI local)
    def create_code(self, name=None, ttl=DEFAULT_TTL):
        """-> {"id","code","name","expires_at"}. El código en claro solo existe en este valor de retorno."""
        ttl = float(ttl)
        if not 1 <= ttl <= MAX_TTL:
            raise PairError(400, "ttl fuera de rango (1 s a 1 h)")
        if name is not None and (not isinstance(name, str) or len(name) > 128 or any(ord(c) < 32 for c in name)):
            raise PairError(400, "nombre inválido")
        code = "".join(secrets.choice(ALPHABET) for _ in range(CODE_LEN))
        salt = secrets.token_hex(16)
        now = self.clock()
        cid = "pc-" + secrets.token_hex(4)
        with db.tx():
            self.conn.execute("INSERT INTO pair_codes(id,code_hash,salt,name,created_at,expires_at) VALUES(?,?,?,?,?,?)",
                              (cid, _code_hash(salt, code), salt, name, now, now + ttl))
        return {"id": cid, "code": code[:4] + "-" + code[4:], "name": name, "expires_at": now + ttl}

    # -- canje (POST /pair)
    def _ip_blocked(self, ip, now):
        with self._lock:
            recent = [t for t in self._fails.get(ip, []) if now - t < IP_WINDOW]
            if recent:
                self._fails[ip] = recent
            else:
                self._fails.pop(ip, None)
            if len(self._fails) > 4096:          # tope de memoria: se olvidan las IPs sin fallos recientes
                self._fails = {k: v for k, v in self._fails.items() if v and now - v[-1] < IP_WINDOW}
            return len(recent) >= IP_FAILS

    def _fail(self, ip, now):
        with self._lock:
            self._fails.setdefault(ip, []).append(now)
        with db.tx():                            # cada fallo cuenta contra todos los códigos vivos
            self.conn.execute("UPDATE pair_codes SET failures=failures+1 WHERE used_at IS NULL AND invalidated_at IS NULL"
                              " AND expires_at>?", (now,))
            self.conn.execute("UPDATE pair_codes SET invalidated_at=? WHERE used_at IS NULL AND invalidated_at IS NULL"
                              " AND failures>=?", (now, CODE_FAILS))

    def redeem(self, code, device_name=None, device_id=None, ip=""):
        """-> {"device_id","credential"} o PairError. Consume el código al primer canje exitoso."""
        now = self.clock()
        if self._ip_blocked(ip, now):
            raise PairError(429, "demasiados intentos: espera un minuto")
        if device_name is not None and (not isinstance(device_name, str) or len(device_name) > 128
                                        or any(ord(c) < 32 for c in device_name)):
            raise PairError(400, "device_name debe ser texto (máx. 128 caracteres, sin controles)")
        if device_id is not None and (not isinstance(device_id, str) or not _ID.match(device_id)):
            raise PairError(400, "device_id tiene caracteres no permitidos")
        canon = normalize(code)
        with db.tx():
            rows = db.rows(self.conn.execute("SELECT id,code_hash,salt,name,expires_at,used_at,invalidated_at FROM pair_codes"))
            hit = None
            for r in rows:                       # sin cortocircuito: el tiempo no depende de cuál coincide
                ok = hmac.compare_digest(_code_hash(r["salt"], canon or "-"), r["code_hash"])
                if ok and canon:
                    hit = r
            if hit is not None and hit["used_at"] is None and hit["invalidated_at"] is None and hit["expires_at"] > now:
                dev = device_id or str(uuid.uuid4())
                cred = CRED_PREFIX + base64.urlsafe_b64encode(secrets.token_bytes(32)).decode("ascii").rstrip("=")
                name = device_name or hit["name"]
                # el mismo device_id puede re-emparejarse: credencial nueva, la anterior deja de valer
                self.conn.execute("INSERT INTO devices(id,name,cred_hash,created_at,last_seen_at,last_ip,revoked_at)"
                                  " VALUES(?,?,?,?,?,?,NULL) ON CONFLICT(id) DO UPDATE SET name=excluded.name,"
                                  " cred_hash=excluded.cred_hash, created_at=excluded.created_at, last_seen_at=excluded.last_seen_at,"
                                  " last_ip=excluded.last_ip, revoked_at=NULL",
                                  (dev, name, _cred_hash(cred), now, now, ip or None))
                self.conn.execute("UPDATE pair_codes SET used_at=?, device_id=? WHERE id=?", (now, dev, hit["id"]))
                return {"device_id": dev, "credential": cred}
        self._fail(ip, now)
        if hit is not None:
            raise PairError(410, "el código ya se usó, caducó o fue invalidado: crea otro con `chopshop pair create`")
        raise PairError(401, "código de emparejamiento inválido")

    # -- uso
    def check(self, cred, ip=None):
        """id del dispositivo dueño de la credencial (no revocada) o None."""
        if not isinstance(cred, str) or not _CRED.match(cred):
            return None
        with db.tx():
            r = self.conn.execute("SELECT id FROM devices WHERE cred_hash=? AND revoked_at IS NULL", (_cred_hash(cred),)).fetchone()
        if r is None:
            return None
        now = self.clock()
        if now - self._seen.get(r["id"], 0) >= SEEN_EVERY:
            self._seen[r["id"]] = now
            with db.tx():
                self.conn.execute("UPDATE devices SET last_seen_at=?, last_ip=COALESCE(?, last_ip) WHERE id=?", (now, ip, r["id"]))
        return r["id"]

    def active(self, device_id):
        """True si el dispositivo existe y no está revocado (el SSE lo comprueba en cada vuelta)."""
        with db.tx():
            return self.conn.execute("SELECT 1 FROM devices WHERE id=? AND revoked_at IS NULL", (device_id,)).fetchone() is not None

    # -- gestión (CLI local)
    def list(self):
        """{"devices":[...], "codes":[...vivos]}: ids, nombres, fechas e IP. Nunca hashes, sales ni credenciales."""
        now = self.clock()
        with db.tx():
            devs = db.rows(self.conn.execute("SELECT id,name,created_at,last_seen_at,last_ip,revoked_at FROM devices ORDER BY created_at"))
            codes = db.rows(self.conn.execute(
                "SELECT id,name,created_at,expires_at,failures FROM pair_codes WHERE used_at IS NULL AND invalidated_at IS NULL"
                " AND expires_at>? ORDER BY created_at", (now,)))
        return {"devices": devs, "codes": codes}

    def revoke(self, ident):
        """Revoca un dispositivo o invalida un código vivo por id. -> "device" | "code" | None."""
        now = self.clock()
        with db.tx():
            if self.conn.execute("UPDATE devices SET revoked_at=? WHERE id=? AND revoked_at IS NULL", (now, ident)).rowcount:
                return "device"
            if self.conn.execute("UPDATE pair_codes SET invalidated_at=? WHERE id=? AND used_at IS NULL AND invalidated_at IS NULL",
                                 (now, ident)).rowcount:
                return "code"
        return None

    def prune(self):
        """Borra códigos usados/caducados/invalidados (más de 7 días) y dispositivos revocados. -> {"codes","devices"}."""
        cut = self.clock() - KEEP_USED
        with db.tx():
            c = self.conn.execute("DELETE FROM pair_codes WHERE (used_at IS NOT NULL OR invalidated_at IS NOT NULL OR expires_at<=?)"
                                  " AND MAX(COALESCE(used_at,0), COALESCE(invalidated_at,0), expires_at)<?", (self.clock(), cut)).rowcount
            d = self.conn.execute("DELETE FROM devices WHERE revoked_at IS NOT NULL").rowcount
        return {"codes": max(0, c), "devices": max(0, d)}


# ---------------------------------------------------------------- CLI `chopshop pair`

def _when(ts):
    return "-" if not ts else time.strftime("%Y-%m-%d %H:%M", time.localtime(ts))


def build_parser():
    p = argparse.ArgumentParser(prog="chopshop pair", description="Emparejamiento de dispositivos con el chopshop-agent de esta máquina")
    sp = p.add_subparsers(dest="cmd", required=True)
    x = sp.add_parser("create", help="crea un código de un solo uso (se muestra una vez)")
    x.add_argument("--name", help="nombre del dispositivo (p. ej. \"MacBook\")")
    x.add_argument("--ttl", default="10m", help="caducidad: 90s, 10m, 1h (máx. 1h; por defecto 10m)")
    x.add_argument("--json", action="store_true", help="salida JSON {id,code,name,expires_at} (para la app de Mac en esta máquina)")
    x = sp.add_parser("list", help="dispositivos y códigos vivos (sin secretos)")
    x.add_argument("--json", action="store_true")
    x = sp.add_parser("revoke", help="revoca un dispositivo o invalida un código (efecto inmediato)")
    x.add_argument("id", help="device_id o id de código (pc-...)")
    sp.add_parser("prune", help="borra códigos usados/caducados y dispositivos revocados")
    return p


def main(argv, stdout=None, stderr=None, conn=None, clock=time.time):
    out, err = stdout or sys.stdout, stderr or sys.stderr
    try:
        a = build_parser().parse_args(argv)
    except SystemExit as e:
        return e.code if isinstance(e.code, int) else 2
    own = conn is None
    if own:
        from . import config
        conn = db.connect(config.load()["db_path"])
    try:
        pr = Pairing(conn, clock)
        if a.cmd == "create":
            try:
                res = pr.create_code(a.name, parse_ttl(a.ttl))
            except (ValueError, PairError) as e:
                print("error: %s" % getattr(e, "message", e), file=err)
                return 2
            if a.json:
                print(json.dumps(res, ensure_ascii=False), file=out)
                return 0
            print("código: %s  (id %s, caduca %s; un solo uso, no se vuelve a mostrar)"
                  % (res["code"], res["id"], _when(res["expires_at"])), file=out)
            return 0
        if a.cmd == "list":
            res = pr.list()
            if a.json:
                print(json.dumps(res, ensure_ascii=False), file=out)
                return 0
            print("dispositivos:", file=out)
            for d in res["devices"]:
                print("  %s  %s  creado %s  último uso %s  ip %s%s" % (
                    d["id"], d["name"] or "-", _when(d["created_at"]), _when(d["last_seen_at"]), d["last_ip"] or "-",
                    "  REVOCADO %s" % _when(d["revoked_at"]) if d["revoked_at"] else ""), file=out)
            print("códigos vivos:", file=out)
            for c in res["codes"]:
                print("  %s  %s  creado %s  caduca %s" % (c["id"], c["name"] or "-", _when(c["created_at"]), _when(c["expires_at"])),
                      file=out)
            return 0
        if a.cmd == "revoke":
            what = pr.revoke(a.id)
            if not what:
                print("error: no hay dispositivo activo ni código vivo con id %s" % a.id, file=err)
                return 1
            print({"device": "dispositivo revocado", "code": "código invalidado"}[what] + ": %s" % a.id, file=out)
            return 0
        res = pr.prune()
        print("borrados: %d códigos, %d dispositivos revocados" % (res["codes"], res["devices"]), file=out)
        return 0
    finally:
        if own:
            conn.close()
