#!/usr/bin/env python3
"""Genera las capturas de assets/ con datos FICTICIOS (fixture.json), sin servidores.

Toma el bundle estático de la UI (apps/mac/Resources/web), genera un HTML en un directorio
temporal que emula el puente nativo (window.webkit.messageHandlers.chopshop) alimentándolo con
el fixture, y lo captura con Chromium headless vía file:// (playwright, solo como librería).

    python3 tools/screenshots/shoot.py [--out assets] [--only overview,graph] [--build]

Requisitos: `pip install playwright && playwright install chromium` y alguna fuente del sistema.
"""
import argparse
import json
import math
import os
import shutil
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, "..", ".."))
WEB = os.path.join(ROOT, "apps", "mac", "Resources", "web")
HIST = 60  # igual que App.jsx: una muestra cada 3 s

# nombre del archivo -> hash que lee el stub (vista[:argumento])
SCENES = {
    "overview": "overview",
    "machines": "machines:host-b",
    "project": "project:proyecto-demo",
    "questions": "questions",
    "graph": "graph",
    "reactions": "reactions",
    "events": "events",
    "batches": "batches",
}

# Escenas que necesitan otro tamaño (el grafo es ancho).
SIZES = {"graph": "1440x800"}

# Fondo que en la app pone el shell SwiftUI (la web es transparente sobre vidrio nativo).
BACKDROP = """<style>
html{background:radial-gradient(1100px 700px at 15% 0%,#26418f 0%,transparent 60%),
radial-gradient(900px 700px at 100% 100%,#4a2a7a 0%,transparent 60%),#0d1330}
</style>"""

STUB = """<script>
window.__FIXTURE__ = %s;
window.webkit = {messageHandlers: {chopshop: {postMessage: function (m) {
  if (m.type !== "ready") return;
  setTimeout(function () {
    var f = window.__FIXTURE__, parts = location.hash.slice(1).split(":");
    var sel = {view: parts[0] || "overview"};
    if (parts[0] === "project") sel.project = parts[1] || "";
    if (parts[0] === "machines") sel.machine = parts[1] || "";
    window.chopshop.receive({type: "state", payload: f.state});
    window.chopshop.receive({type: "metrics", payload: {machines: f.metrics}});
    window.chopshop.receive({type: "select", payload: sel});
  }, 0);
}}}};
</script>"""


def series(spec, phase, lo=0.0, hi=100.0, integer=False):
    """Serie suave y determinista de HIST muestras alrededor de base ± amp."""
    out = []
    for i in range(HIST):
        v = spec["base"] + spec["amp"] * (0.6 * math.sin(i / 5.0 + phase) + 0.4 * math.sin(i / 2.3 + 2 * phase))
        v = min(hi, max(lo, v))
        out.append(round(v) if integer else round(v, 1))
    return out


def machines(fx):
    out = []
    for n, (name, m) in enumerate(fx["metrics"].items()):
        cpu = series(m["cpu"], n)
        row = {k: v for k, v in m.items() if k not in ("cpu", "ram", "run")}
        row.update(name=name, cpu=cpu, ram=series(m["ram"], n + 1),
                   load1=[round(c / 100.0 * m["cpus"], 2) for c in cpu],
                   run=series(m["run"], n + 2, 0, 4, integer=True))
        out.append(row)
    return out


def build_page(tmp, fx):
    for f in ("app.js", "app.css"):
        shutil.copy(os.path.join(WEB, f), os.path.join(tmp, f))
    html = open(os.path.join(WEB, "index.html"), encoding="utf-8").read()
    payload = {"state": fx["state"], "metrics": machines(fx)}
    html = html.replace("<title>", BACKDROP + "<title>", 1)
    html = html.replace('<script src="app.js">', STUB % json.dumps(payload, ensure_ascii=False) + '\n<script src="app.js">', 1)
    path = os.path.join(tmp, "index.html")
    with open(path, "w", encoding="utf-8") as f:
        f.write(html)
    return path


def build_bundle(tmp):
    """Recompila la UI a un directorio temporal (sin tocar apps/mac/Resources/web)."""
    global WEB
    ui = os.path.join(ROOT, "apps", "ui")
    out = os.path.join(tmp, "web")
    os.makedirs(out)
    subprocess.check_call([os.path.join(ui, "node_modules", ".bin", "esbuild"), "src/main.jsx", "--bundle", "--format=iife",
                           "--jsx=automatic", "--target=chrome120", "--outfile=" + os.path.join(out, "app.js")], cwd=ui)
    for f in ("index.html", "app.css"):
        shutil.copy(os.path.join(ui, "src", f), os.path.join(out, f))
    WEB = out


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--out", default=os.path.join(ROOT, "assets"))
    ap.add_argument("--only", default="", help="lista separada por comas de: " + ", ".join(SCENES))
    ap.add_argument("--build", action="store_true", help="recompilar la UI desde apps/ui en vez de usar el bundle de la app")
    ap.add_argument("--size", default="1200x760")
    a = ap.parse_args()
    try:
        from playwright.sync_api import sync_playwright
    except ImportError:
        sys.exit("falta playwright: pip install playwright && playwright install chromium")
    fx = json.load(open(os.path.join(HERE, "fixture.json"), encoding="utf-8"))
    names = [s for s in a.only.split(",") if s] or list(SCENES)
    bad = [s for s in names if s not in SCENES]
    if bad:
        sys.exit("escenas desconocidas: " + ", ".join(bad))
    os.makedirs(a.out, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="chopshop-shots-") as tmp:
        if a.build:
            build_bundle(tmp)
        page_path = build_page(tmp, fx)
        with sync_playwright() as p:
            browser = p.chromium.launch()
            ctx = browser.new_context(device_scale_factor=1, reduced_motion="reduce",
                                      locale="es-MX", timezone_id="America/Mexico_City")
            for name in names:
                w, h = (int(x) for x in SIZES.get(name, a.size).split("x"))
                page = ctx.new_page()
                page.set_viewport_size({"width": w, "height": h})
                page.clock.set_fixed_time(fx["now"])
                page.goto("file://" + page_path + "#" + SCENES[name])
                page.wait_for_selector("main.page .view")
                page.wait_for_timeout(700)
                dest = os.path.join(a.out, name + ".png")
                page.screenshot(path=dest)
                page.close()
                print("%s (%d KB)" % (dest, os.path.getsize(dest) // 1024))
            browser.close()


if __name__ == "__main__":
    main()
