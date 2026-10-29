#!/usr/bin/env python3
"""Escena de la oficina con muchos hilos (el caso de «chopshop · 46 hilos, 1 corriendo»): un `.jsonl` de sobres para el modo demo
de la app (`--demo-fixture`) y para mirar a ojo la rejilla de pisos, los escritorios por rol, el vestíbulo y la semivida.

    python3 apps/mac/Tests/ChopshopNativeTests/tools/make_office_layout_fixture.py /tmp/office-46.jsonl [--no-office] [--now ISO]

- 46 hilos de `chopshop`: 1 corriendo y 45 terminados (uno cada 7 min hacia atrás; 1 de cada 9 fallido), con `ended_at`.
- Con perfil (por defecto): `office.changed` con un piso «Producto» (triage permanente, mac 4, agent 4, ui 3, docs 2) y los
  `desk.assigned` / `desk.released` (`inherited`, `faded`) que emitiría `agent/office.py`; los hilos sin rol pasan por el vestíbulo.
- `--no-office`: el mismo proyecto sin bloque `office` (la app arma pisos sintéticos por rol y el vestíbulo con lo que queda).
Los tiempos son relativos a `--now` (por defecto, ahora): la semivida se ve igual al reproducirlo enseguida. Datos inventados."""
import argparse
import datetime as dt
import json
import sys

PROJECT = "chopshop"
HALF_LIFE = 1800
FADE = 3.3219280948873622        # log2(1 / 0.1): semividas hasta opacidad 0.1
ROLES = ["mac", "agent", "ui", "docs", None]
ROOMS = [("triage", 1, True), ("mac", 4, False), ("agent", 4, False), ("ui", 3, False), ("docs", 2, False)]
TOPICS = {
    "mac": ["oficina por pisos", "zoom de la ciudad", "sala de máquinas", "inspector del escritorio", "menú de la barra",
            "tests de equivalencia", "capturas headless", "atajos de teclado", "modo claro"],
    "agent": ["semivida de hilos", "webhooks salientes", "forge con ETag", "perfil de oficina", "vestíbulo", "rack de repos",
              "migración v6", "triage diario", "linaje de escritorios"],
    "ui": ["vista de lotes", "preguntas abiertas", "actividad", "grafo de tareas", "reacciones", "resumen", "máquinas",
           "tema oscuro", "tabla de eventos"],
    "docs": ["guía de emparejado", "API v3", "sobres nuevos", "capturas", "plan de la oficina", "release", "README",
             "automatizaciones", "servicio del agente"],
    None: ["revisar dependencias", "pregunta suelta", "limpiar ramas", "probar el stream", "bisect de un test", "medir arranque",
           "ordenar issues", "renombrar módulos", "notas de la reunión"],
}


def iso(t):
    return dt.datetime.fromtimestamp(t, dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.%f")[:-3] + "Z"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("out")
    ap.add_argument("--no-office", action="store_true")
    ap.add_argument("--now", help="instante de referencia ISO (por defecto, ahora)")
    a = ap.parse_args()
    now = dt.datetime.fromisoformat(a.now.replace("Z", "+00:00")).timestamp() if a.now else dt.datetime.now(dt.timezone.utc).timestamp()
    office = not a.no_office
    ev = []

    def env(ts, typ, subject, body, severity="info", needs=None):
        ev.append({"v": 1, "ts": ts, "machine": "host-a", "project": PROJECT, "type": typ, "severity": severity, "needs": needs,
                   "subject": subject, "body": body})

    def task(ts, tid, title, phase, role, ended=None, severity="info"):
        env(ts, "task.state", {"kind": "task", "id": tid, "title": title},
            {"phase": phase, "attention": None, "thread_id": tid, "settled": False, "title": title, "role": role,
             "ended_at": iso(ended) if ended else None, "touched_at": None}, severity=severity)

    if office:
        rooms = [{"role": r, "permanent": p, "desks": [{"id": "%s/0/%s/%d" % (PROJECT, r, k), "slot": k, "retired": False} for k in range(n)]}
                 for r, n, p in ROOMS]
        env(iso(now - 4 * 86400), "office.changed", {"kind": "office", "id": PROJECT},
            {"project": PROJECT, "by": "profile", "company": "Personal", "half_life_s": HALF_LIFE,
             "floors": [{"index": 0, "name": "Producto", "rooms": rooms}]})

    # 46 hilos: el 0 corre; el k-ésimo terminado acabó hace 3 + 7·k min (ventana visible ≈ 100 min, 200 si falló)
    threads = []
    for i in range(46):
        role = ROLES[i % len(ROLES)]
        topic = TOPICS[role][(i // len(ROLES)) % len(TOPICS[role])]
        title = ("[%s] %s" % (role, topic)) if role else topic.capitalize()
        failed = i % 9 == 4
        end = None if i == 0 else now - (3 + 7 * (i - 1)) * 60
        start = (now - 25 * 60) if i == 0 else end - (20 + (i * 13) % 50) * 60
        threads.append({"tid": "mcp:k%02d" % i, "title": title, "role": role, "start": start, "end": end, "failed": failed})

    desks = {r: [None] * n for r, n, _ in ROOMS}           # ocupante actual de cada escritorio
    def gone_at(th):
        return th["end"] + HALF_LIFE * (2 if th["failed"] else 1) * FADE

    for th in sorted(threads, key=lambda t: t["start"]):
        tid, role = th["tid"], (th["role"] if office else th["role"])
        task(iso(th["start"]), tid, th["title"], "running", role)
        if office and role:
            slots = desks[role]
            # primer escritorio libre o en semivida (herencia); el terminado más antiguo cede primero
            free = [k for k, o in enumerate(slots) if o is None or (o["end"] is not None and gone_at(o) <= th["start"])]
            fading = sorted((k for k, o in enumerate(slots) if o is not None and o["end"] is not None and o["end"] <= th["start"]
                             and k not in free), key=lambda k: slots[k]["end"])
            k = (free or fading or [None])[0]
            if k is not None:
                prev = slots[k]
                did = "%s/0/%s/%d" % (PROJECT, role, k)
                if prev is not None and gone_at(prev) > th["start"]:
                    env(iso(th["start"] + 0.5), "desk.released", {"kind": "desk", "id": did},
                        {"desk": did, "thread_id": prev["tid"], "reason": "inherited"})
                body = {"desk": did, "thread_id": tid, "role": role, "reason": "inherited" if prev else "start"}
                if prev:
                    body["inheritance"] = {"thread_id": prev["tid"], "title": prev["title"], "summary": "Terminado: %s." % prev["title"],
                                           "phase": "failed" if prev["failed"] else "done"}
                env(iso(th["start"] + 1), "desk.assigned", {"kind": "desk", "id": did}, body)
                slots[k] = th
                th["desk"] = did
            else:
                env(iso(th["start"] + 1), "desk.waiting", {"kind": "thread", "id": tid},
                    {"thread_id": tid, "role": role, "title": th["title"], "phase": "running"})
        if th["end"] is not None:
            ph = "failed" if th["failed"] else "done"
            task(iso(th["end"]), tid, th["title"], ph, role, ended=th["end"], severity="error" if th["failed"] else "info")
            g = gone_at(th)
            if office and g < now:
                env(iso(g), "desk.released", {"kind": "desk", "id": th.get("desk") or tid},
                    {"desk": th.get("desk"), "thread_id": tid, "reason": "faded"})
    # sala de máquinas: dos repos en el rack (uno con CI en curso) y los listeners del agente
    for repo, label, light in (("<org>/chopshop", "chopshop", "amber"), ("<org>/chopshop-docs", "docs", "green")):
        env(iso(now - 120), "forge.repo.state", {"kind": "repo", "id": "github:" + repo},
            {"provider": "github", "repo": repo, "project": PROJECT, "kind": "main", "label": label, "light": light,
             "default_branch": "main", "ci": "success", "error": None})
    for name, st in (("t3watch", "ok"), ("forge", "ok"), ("webhooks", "degraded")):
        env(iso(now - 60), "listener.state", {"kind": "listener", "id": name},
            {"name": name, "state": st, "last_ok": iso(now - 60), "last_cycle": iso(now - 60), "backoff_s": 0, "error": None},
            severity="info" if st == "ok" else "warn")
    # los desk.released de un hilo ya heredado no encuentran ocupante: inofensivos, como en el agente
    ev.sort(key=lambda e: e["ts"])
    for i, e in enumerate(ev, 1):
        e["id"] = "office-layout-%d" % i
        e["seq"] = i
    with open(a.out, "w") as f:
        for e in ev:
            f.write(json.dumps(e, ensure_ascii=False) + "\n")
    print("%d sobres -> %s" % (len(ev), a.out), file=sys.stderr)


if __name__ == "__main__":
    main()
