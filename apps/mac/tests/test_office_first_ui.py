"""Invariantes de la interfaz centrada en la oficina (docs/plans/office-first-ui.md), comprobables sin Swift ni macOS.

- La vista Grafo no vuelve: ni en la app nativa, ni en la UI web, ni en las capturas.
- Sin tooltips sobre el mundo (ciudad, pisos, oficina) ni en el armazón.
- Los atajos de `ShellKeymap.all` (Swift) y la tabla «Atajos» del plan son la misma lista.
- Cada panel del armazón tiene sitio en la tabla «Qué se queda de cada pantalla».

    cd apps/mac && python3 -m unittest discover -s tests
"""
import os
import re
import unittest

MAC = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ROOT = os.path.dirname(os.path.dirname(MAC))
NATIVE = os.path.join(MAC, "Sources", "ChopshopNative")
UI = os.path.join(MAC, "Sources", "ChopshopUI")
PLAN = os.path.join(ROOT, "docs", "plans", "office-first-ui.md")
SHELL_MODEL = os.path.join(NATIVE, "Shell", "ShellModel.swift")


def read(path):
    with open(path, encoding="utf-8") as f:
        return f.read()


def swift_files(*dirs):
    for d in dirs:
        for base, _, names in os.walk(d):
            for n in sorted(names):
                if n.endswith(".swift"):
                    yield os.path.join(base, n)


def section(md, title):
    """Texto de la sección `## title` hasta la siguiente `## `."""
    m = re.search(r"^## " + re.escape(title) + r"\n(.*?)(?=^## |\Z)", md, re.S | re.M)
    if not m:
        raise AssertionError(f"falta la sección «{title}» en el plan")
    return m.group(1)


def table_rows(text):
    rows = []
    for line in text.splitlines():
        line = line.strip()
        if not line.startswith("|") or set(line) <= set("|-: "):
            continue
        cells = [c.strip() for c in line.strip("|").split("|")]
        rows.append(cells)
    return rows[1:]  # sin la cabecera


class NoGraphView(unittest.TestCase):
    GONE = ["GraphView", "GraphBackdrop", "GraphCameraBox", "GraphMode", "ModeSwitch", "GraphRenderer"]

    def test_native_graph_view_is_gone(self):
        self.assertFalse(os.path.exists(os.path.join(NATIVE, "GraphView.swift")))
        dirs = [os.path.join(MAC, "Sources"), os.path.join(MAC, "Tests"), os.path.join(MAC, "native", "Sources")]
        for path in swift_files(*dirs):
            if os.path.islink(os.path.dirname(path)):
                continue
            text = read(path)
            for sym in self.GONE:
                self.assertIsNone(re.search(r"\b" + sym + r"\b", text), f"{sym} en {os.path.relpath(path, MAC)}")

    def test_sidebar_has_no_graph_section(self):
        model = read(os.path.join(UI, "Model.swift"))
        self.assertNotRegex(model, r"\bcase\s+\.graph\b")
        self.assertNotIn('"Grafo"', model)
        enum = re.search(r"enum Section[^{]*\{\s*case ([^\n]+)", model).group(1)
        self.assertNotIn("graph", [c.strip() for c in enum.split(",")])

    def test_city_switch_has_no_graph_segment(self):
        city = read(os.path.join(NATIVE, "City", "CityView.swift"))
        self.assertNotIn('"Grafo"', city)
        self.assertNotIn("showGraph", city)

    def test_web_graph_view_is_gone(self):
        app = read(os.path.join(ROOT, "apps", "ui", "src", "App.jsx"))
        self.assertNotRegex(app, r"function Graph\w*\(")
        self.assertNotIn('view === "graph"', app)
        self.assertNotRegex(app, r"export \{[^}]*\bGraph\b")
        css = read(os.path.join(ROOT, "apps", "ui", "src", "app.css"))
        self.assertNotIn(".gnode", css)
        bundle = read(os.path.join(MAC, "Resources", "web", "app.js"))
        self.assertNotIn("Planificador", bundle, "el bundle web se regeneró sin la vista Grafo (pnpm --filter @chopshop/ui build)")

    def test_screenshots_have_no_graph_scene(self):
        shoot = read(os.path.join(ROOT, "tools", "screenshots", "shoot.py"))
        self.assertNotRegex(shoot, r'"graph"\s*:')
        self.assertFalse(os.path.exists(os.path.join(ROOT, "assets", "graph.png")))
        snap = read(os.path.join(MAC, "native", "Sources", "ChopshopSnap", "main.swift"))
        self.assertNotIn("grafo.png", snap)


class NoTooltipsOnTheWorld(unittest.TestCase):
    WORLD = [os.path.join(NATIVE, "City"), os.path.join(NATIVE, "Office"), os.path.join(NATIVE, "Shell")]
    FILES = [os.path.join(NATIVE, n) for n in ("IsoOfficeView.swift", "IsoRender.swift", "IsoScene.swift")]

    def test_no_help_popover_or_hover_cards(self):
        paths = list(swift_files(*self.WORLD)) + self.FILES
        self.assertTrue(any(p.endswith("OfficeShell.swift") for p in paths))
        for path in paths:
            text = read(path)
            rel = os.path.relpath(path, MAC)
            self.assertNotIn(".help(", text, f"tooltip en {rel}")
            self.assertNotIn(".popover(", text, f"popover en {rel}")
            self.assertNotIn("IsoTooltip", text, f"tarjeta de hover en {rel}")


class KeymapMatchesPlan(unittest.TestCase):
    ENTRY = re.compile(r'ShellShortcut\(\.(\w+),\s*"((?:\\\\|[^"])*)"(,\s*shift:\s*true)?,\s*"([^"]*)"\)')

    def keymap(self):
        src = read(SHELL_MODEL)
        block = re.search(r"static let all: \[ShellShortcut\] = \[(.*?)\n    \]", src, re.S).group(1)
        out = []
        for action, key, shift, title in self.ENTRY.findall(block):
            key = key.replace("\\\\", "\\")
            display = "Esc" if key == "esc" else ("⇧" if shift else "") + "⌘" + key.upper()
            out.append((action, display, title))
        return out

    def test_keymap_is_parsed(self):
        km = self.keymap()
        self.assertGreaterEqual(len(km), 10)
        self.assertIn(("palette", "⌘K", "Paleta de órdenes"), km)
        self.assertIn(("toggleInspector", "⌘\\", "Mostrar u ocultar el panel"), km)

    def test_plan_table_is_the_keymap(self):
        rows = table_rows(section(read(PLAN), "Atajos"))
        plan = [(r[0], r[1]) for r in rows]
        swift = [(d, t) for _, d, t in self.keymap()]
        self.assertEqual(plan, swift, "la tabla «Atajos» del plan y ShellKeymap.all deben coincidir (mismo orden)")

    def test_no_duplicate_shortcuts(self):
        displays = [d for _, d, _ in self.keymap()]
        self.assertEqual(len(displays), len(set(displays)))

    def test_every_action_has_a_shortcut(self):
        src = read(SHELL_MODEL)
        enum = re.search(r"public enum ShellAction[^{]*\{(.*?)\n\n", src, re.S).group(1)
        actions = set(re.findall(r"\b(\w+)\b", " ".join(l.split("case", 1)[1] for l in enum.splitlines() if "case" in l)))
        self.assertEqual(actions, {a for a, _, _ in self.keymap()})


class PanelsHaveAHome(unittest.TestCase):
    def test_every_panel_is_in_the_keep_table(self):
        src = read(SHELL_MODEL)
        titles = re.findall(r'case \.\w+: return "([^"]+)"', src[src.index("enum ShellPanel"):src.index("public var symbol")])
        self.assertEqual(len(titles), 6)
        keep = section(read(PLAN), "Qué se queda de cada pantalla")
        for t in titles:
            self.assertIn(f"panel {t}", keep, f"el panel {t} no aparece en «Qué se queda de cada pantalla»")


if __name__ == "__main__":
    unittest.main()
