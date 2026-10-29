"""Notas de bots en escritorios para preparar el día (docs/plans/office-redesign.md §5, `POST /desks/<id>/notes`).

Un bot (Grok) deja una nota en la bandeja de un escritorio; queda pendiente hasta que la consume el hilo que despierta en ese
escritorio (rol permanente, `wake`) o el hilo activo en su próximo turno, o hasta que caduca (`ttl_s`, 24 h por defecto).
Cada nota nueva emite `desk.note` con `pending` (notas sin consumir tras esta) para que la proyección pinte `notes_pending`.

- `add(conn, desk, frm, text, ttl_s, now) -> {id, desk, from, text, created, expires}`; `body(note, pending)` = cuerpo de
  `desk.note`.
- `pending(conn, desk, now)` / `count(conn, desk, now)`: notas vivas (sin consumir y sin caducar), las más viejas primero.
- `consume(conn, desk, now, by)`: marca las vivas como consumidas por `by` (id del hilo) y las devuelve, para el prompt.
- `prompt_block(notes)`: texto para el prompt de arranque o un `t3_thread_send` (mensaje interno a T3, nunca externo).
- `prune(conn, now, keep_s)`: borra consumidas/caducadas con más de `keep_s` (mantenimiento).
- `declared_desk(desk)`: el escritorio según el perfil local (None si no existe o no es válido).
Tabla propia `desk_notes`, creada de forma idempotente (no toca `user_version`)."""
import time
import uuid

from . import db, envelope, layout

MAX_TEXT = 2048                    # bytes UTF-8 (el sobre lo trunca a 2 KB)
MAX_FROM = 64
DEFAULT_TTL = 86400                # s
MIN_TTL = 60
MAX_TTL = 7 * 86400
MAX_PENDING = 50                   # notas vivas por escritorio (la más vieja se descarta al pasarse)
KEEP_S = 7 * 86400                 # consumidas/caducadas que se conservan antes de borrarlas

SCHEMA = ('CREATE TABLE IF NOT EXISTS desk_notes (id TEXT PRIMARY KEY, desk_id TEXT NOT NULL, "from" TEXT NOT NULL,'
          " text TEXT NOT NULL, created REAL NOT NULL, expires REAL NOT NULL, consumed REAL, consumed_by TEXT)",
          "CREATE INDEX IF NOT EXISTS desk_notes_desk ON desk_notes(desk_id, consumed, expires)")


class NoteError(ValueError):
    """Nota inválida; el mensaje llega al cliente."""


def ensure(conn):
    with db.tx():                  # idempotente y barato; sin executescript (no hace COMMIT implícito)
        for sql in SCHEMA:
            conn.execute(sql)


def truncate(text, limit=MAX_TEXT):
    """Corta a `limit` bytes UTF-8 sin partir caracteres."""
    raw = text.encode("utf-8")
    return text if len(raw) <= limit else raw[:limit].decode("utf-8", "ignore")


def clean(frm, text, ttl_s=None):
    """Valida los campos de `POST /desks/<id>/notes` -> (from, text, ttl_s) o NoteError."""
    if not isinstance(frm, str) or not frm.strip() or len(frm) > MAX_FROM or any(ord(c) < 32 for c in frm):
        raise NoteError("from debe ser un nombre (máx. %d caracteres, sin controles)" % MAX_FROM)
    if not isinstance(text, str) or not text.strip():
        raise NoteError("text es obligatorio")
    if len(text.encode("utf-8")) > MAX_TEXT:
        raise NoteError("text supera 2 KB")
    if any(ord(c) < 32 and c not in "\n\t" for c in text):
        raise NoteError("text no admite caracteres de control (salvo salto de línea y tabulador)")
    if ttl_s is None:
        ttl_s = DEFAULT_TTL
    if isinstance(ttl_s, bool) or not isinstance(ttl_s, (int, float)) or not MIN_TTL <= ttl_s <= MAX_TTL:
        raise NoteError("ttl_s fuera de rango (%d..%d s)" % (MIN_TTL, MAX_TTL))
    return frm.strip(), text.strip(), float(ttl_s)


def _note(r):
    return {"id": r["id"], "desk": r["desk_id"], "from": r["from"], "text": r["text"], "created": r["created"],
            "expires": r["expires"], "consumed": r["consumed"], "consumed_by": r["consumed_by"]}


def add(conn, desk, frm, text, ttl_s=None, now=None):
    frm, text, ttl_s = clean(frm, text, ttl_s)
    now = time.time() if now is None else now
    ensure(conn)
    note = {"id": uuid.uuid4().hex[:16], "desk": desk, "from": frm, "text": truncate(text), "created": now,
            "expires": now + ttl_s, "consumed": None, "consumed_by": None}
    with db.tx():
        conn.execute('INSERT INTO desk_notes(id, desk_id, "from", text, created, expires) VALUES(?,?,?,?,?,?)',
                     (note["id"], desk, frm, note["text"], now, note["expires"]))
        extra = conn.execute("SELECT id FROM desk_notes WHERE desk_id=? AND consumed IS NULL AND expires>? "
                             "ORDER BY created DESC, rowid DESC LIMIT -1 OFFSET ?", (desk, now, MAX_PENDING)).fetchall()
        for r in extra:                                  # bandeja llena: las más viejas caducan ya
            conn.execute("UPDATE desk_notes SET expires=? WHERE id=?", (now, r["id"]))
    return note


def pending(conn, desk, now):
    ensure(conn)
    with db.tx():
        rows = conn.execute("SELECT * FROM desk_notes WHERE desk_id=? AND consumed IS NULL AND expires>? "
                            "ORDER BY created, rowid", (desk, now)).fetchall()
    return [_note(r) for r in rows]


def count(conn, desk, now):
    ensure(conn)
    with db.tx():
        return conn.execute("SELECT COUNT(*) FROM desk_notes WHERE desk_id=? AND consumed IS NULL AND expires>?",
                            (desk, now)).fetchone()[0]


def consume(conn, desk, now, by=None):
    """Marca como consumidas las notas vivas del escritorio y las devuelve (las más viejas primero)."""
    ensure(conn)
    with db.tx():
        rows = conn.execute("SELECT * FROM desk_notes WHERE desk_id=? AND consumed IS NULL AND expires>? "
                            "ORDER BY created, rowid", (desk, now)).fetchall()
        conn.executemany("UPDATE desk_notes SET consumed=?, consumed_by=? WHERE id=?", [(now, by, r["id"]) for r in rows])
    return [dict(_note(r), consumed=now, consumed_by=by) for r in rows]


def prune(conn, now, keep_s=KEEP_S):
    ensure(conn)
    cut = now - keep_s
    with db.tx():
        return conn.execute("DELETE FROM desk_notes WHERE (consumed IS NOT NULL AND consumed<?) OR expires<?",
                            (cut, cut)).rowcount


def body(note, pending_n):
    """Cuerpo de `desk.note`."""
    return {"desk": note["desk"], "from": note["from"], "text": truncate(note["text"]), "pending": pending_n,
            "expires": envelope.iso(note["expires"])}


def prompt_block(notes):
    """Notas pendientes como bloque de texto para el prompt del hilo ("" si no hay)."""
    if not notes:
        return ""
    lines = ["Notas pendientes en tu escritorio (de los bots, para preparar el día):"]
    for n in notes:
        lines.append("- [%s · %s] %s" % (n["from"], envelope.iso(n["created"]), n["text"].replace("\n", "\n  ")))
    return "\n".join(lines)


def declared_desk(desk):
    """Escritorio declarado en el perfil local de su proyecto: {id, project, floor, role, slot, permanent} o None."""
    p = layout.parse_desk_id(desk)
    if not p:
        return None
    from .. import profile  # noqa: PLC0415
    try:
        prof = profile.load(p[0])
    except profile.ProfileError:
        return None
    return next((d for d in layout.desks(prof) if d["id"] == desk), None)
