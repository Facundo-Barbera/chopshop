import os
import sys
import unittest

sys.path.insert(0, os.path.dirname(__file__))
sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
from test_chopshop import Env  # noqa: E402
from chopshop import graph, profile, state  # noqa: E402

BUGS = [{"id": "BUG-1", "title": "uno", "text": "x"},
        {"id": "BUG-2", "title": "dos", "text": "requiere BUG-1"},
        {"id": "BUG-3", "title": "tres", "text": "grande", "hint": "split"},
        {"id": "BUG-4", "title": "cuatro", "text": "y"}]
TRIAGE = '[{"bug":"BUG-1","depends_on":[]},{"bug":"BUG-2","depends_on":["BUG-1"]},{"bug":"BUG-3","depends_on":[]},{"bug":"BUG-4","depends_on":[]}]'
PROF = "project: g\nscratch: true\n"
MX = {"hosts": {"host-a": {"ok": True, "stale": False, "cpu_pct": 10, "ram_pct": 40}}}


def finish(b, tid, text, status="completed"):
    t = next(x for x in b["tasks"] if x["id"] == tid)
    t.update(status="launched", done=True, t3status=status, result=text)


class TestGraph(Env):
    def setUp(self):
        super().setUp()
        self.prof("g", PROF)
        self.mx = dict(MX)
        self._orig = graph.metrics.read
        graph.metrics.read = lambda now=None: self.mx

    def tearDown(self):
        graph.metrics.read = self._orig

    def mk(self, extra=""):
        self.prof("g", PROF + extra)
        prof = profile.load("g")
        with state.locked() as st:
            b = {"id": "b-0001", "project": "g", "host": "host-a", "max_parallel": 2, "tasks": [], "created": "x"}
            graph.new_graph(st, b, prof, None, BUGS)
            st["batches"]["b-0001"] = b
        return prof

    def step(self, prof, fn=None):
        with state.locked() as st:
            b = st["batches"]["b-0001"]
            if fn:
                fn(b)
            graph.step(st, b, prof, lambda *a: None)
            self.launched(b)    # el motor lanza lo que quedó en cola
            return st["graphs"]["g-0001"], b

    def launched(self, b):   # simula que el motor lanzó lo que está en cola
        for t in b["tasks"]:
            if t["status"] == "queued":
                t["status"] = "launched"

    def test_full_cycle(self):
        prof = self.mk()
        g, b = self.step(prof)
        self.assertEqual([t["node"] for t in b["tasks"]], ["n1"])            # solo triage
        g, b = self.step(prof, lambda b: (self.launched(b), finish(b, "t-0001-1", TRIAGE)))
        by = {n["label"]: n for n in g["nodes"].values()}
        self.assertEqual(by["BUG-2"]["deps"], [by["BUG-1"]["id"]])
        running = sorted(n["label"] for n in g["nodes"].values() if n["status"] == "running")
        self.assertEqual(running, ["BUG-1", "BUG-3"])                        # cupo 2; BUG-2 espera a BUG-1
        self.assertEqual(by["BUG-2"]["status"], "pending")
        self.launched(b)
        # BUG-1 termina -> BUG-2 se libera (hay un cupo); BUG-3 pide dividirse
        split = 'SPLIT: [{"title":"a","text":"t"},{"title":"b","text":"t"}]'
        g, b = self.step(prof, lambda b: (finish(b, [t for t in b["tasks"] if t["node"] == by["BUG-1"]["id"]][0]["id"], "RESULT: arreglado 1"),
                                          finish(b, [t for t in b["tasks"] if t["node"] == by["BUG-3"]["id"]][0]["id"], split)))
        by = {n["label"]: n for n in g["nodes"].values()}
        self.assertEqual(by["BUG-1"]["status"], "done")
        self.assertEqual(by["BUG-3"]["status"], "expanding")
        self.assertIn("BUG-3.1", by)
        self.assertEqual(by["BUG-3.1"]["depth"], 2)
        tk = next(t for t in b["tasks"] if t["node"] == by["BUG-2"]["id"])
        self.assertIn("arreglado 1", tk["prompt"])                           # el resultado de la dependencia viaja en el prompt
        self.launched(b)
        for _ in range(4):
            def fin(b):
                for t in b["tasks"]:
                    if t["status"] == "launched" and not t["done"]:
                        finish(b, t["id"], "RESULT: ok " + t["node"])
            g, b = self.step(prof, fin)
            self.launched(b)
            if g["status"] != "running":
                break
        self.assertEqual(g["status"], "done")
        by = {n["label"]: n for n in g["nodes"].values()}
        self.assertEqual(by["BUG-3"]["status"], "done")
        self.assertIn("BUG-3.1: ok", by["BUG-3"]["result"])                  # roll-up al padre
        self.assertEqual(g["summary"]["done"], 6)
        self.assertEqual(len(b["tasks"]), 1 + 4 + 2)

    def test_max_depth_and_budget(self):
        prof = self.mk("graph:\n  max_depth: 1\n  thread_budget: 3\n")
        g, b = self.step(prof)
        g, b = self.step(prof, lambda b: (self.launched(b), finish(b, "t-0001-1", TRIAGE)))
        by = {n["label"]: n for n in g["nodes"].values()}
        # presupuesto: triage + 2 = 3 hilos; el resto se omite
        self.assertEqual(len(b["tasks"]), 3)
        self.assertEqual(by["BUG-4"]["status"], "skipped")
        self.assertIn("presupuesto", by["BUG-4"]["reason"])
        self.launched(b)
        split = 'SPLIT: [{"title":"a"},{"title":"b"}]'
        g, b = self.step(prof, lambda b: finish(b, [t for t in b["tasks"] if t["node"] == by["BUG-3"]["id"]][0]["id"], split))
        by = {n["label"]: n for n in g["nodes"].values()}
        self.assertEqual(by["BUG-3"]["status"], "failed")                    # rebasa max_depth
        self.assertIn("max_depth", by["BUG-3"]["reason"])

    def test_failed_dep_blocks_and_ratio(self):
        prof = self.mk("graph:\n  done: ratio\n  min_ratio: 0.5\n")
        self.step(prof)
        g, b = self.step(prof, lambda b: (self.launched(b), finish(b, "t-0001-1", TRIAGE)))
        by = {n["label"]: n for n in g["nodes"].values()}
        t1 = next(t for t in b["tasks"] if t["node"] == by["BUG-1"]["id"])
        self.launched(b)
        g, b = self.step(prof, lambda b: finish(b, t1["id"], "", status="interrupted"))
        by = {n["label"]: n for n in g["nodes"].values()}
        self.assertEqual(by["BUG-1"]["status"], "failed")
        self.assertEqual(by["BUG-2"]["status"], "skipped")                   # dependencia fallida
        for _ in range(5):
            def fin(b):
                for t in b["tasks"]:
                    if t["status"] == "launched" and not t["done"]:
                        finish(b, t["id"], 'SPLIT: [{"title":"x"}]' if t["node"] == by["BUG-3"]["id"] else "RESULT: ok")
            g, b = self.step(prof, fin)
            self.launched(b)
        by = {n["label"]: n for n in g["nodes"].values()}
        self.assertEqual(g["status"], "done")                                # 2 de 4 >= 0.5 (criterio ratio)

    def test_retry_chain_is_followed(self):
        prof = self.mk()
        self.step(prof)
        def retry(b):
            self.launched(b)
            t = b["tasks"][0]
            t.update(done=True, t3status="interrupted", retried_by="t-0001-2")
            b["tasks"].append({"id": "t-0001-2", "node": "n1", "status": "launched", "done": False, "t3status": "running", "prompt": "p", "title": "x"})
        g, b = self.step(prof, retry)
        self.assertEqual(g["nodes"]["n1"]["status"], "running")              # no falla: sigue al reintento
        self.assertEqual(g["nodes"]["n1"]["task"], "t-0001-2")
        g, b = self.step(prof, lambda b: finish(b, "t-0001-2", TRIAGE))
        self.assertEqual(g["nodes"]["n1"]["status"], "done")

    def test_throttle(self):
        prof = self.mk()
        g = {"limits": graph.limits(prof)}
        self.assertEqual(graph.throttle(g, "host-a", 4, 2, MX)[0], 4)
        hot = {"hosts": {"host-a": {"ok": True, "cpu_pct": 80, "ram_pct": 50}}}
        self.assertEqual(graph.throttle(g, "host-a", 4, 2, hot)[0], 2)  # CPU alta: mitad
        sat = {"hosts": {"host-a": {"ok": True, "cpu_pct": 120, "ram_pct": 50}}}
        self.assertEqual(graph.throttle(g, "host-a", 4, 2, sat)[0], 2)  # saturado: nada nuevo (activos = 2)
        self.assertEqual(graph.throttle(g, "host-a", 4, 0, sat)[0], 1)  # pero siempre 1 si no corre nada
        ram = {"hosts": {"host-a": {"ok": True, "cpu_pct": 10, "ram_pct": 95}}}
        self.assertEqual(graph.throttle(g, "host-a", 4, 0, ram)[1]["mode"], "pausa")
        stale = {"hosts": {"host-a": {"ok": True, "stale": True, "cpu_pct": 200}}}
        self.assertEqual(graph.throttle(g, "host-a", 4, 0, stale)[1]["mode"], "sin-datos")
        # el planificador respeta el rendimiento: con CPU saturada y 1 hilo activo no lanza más
        self.mx = sat
        self.step(prof)
        g, b = self.step(prof, lambda b: (self.launched(b), finish(b, "t-0001-1", TRIAGE)))
        self.assertEqual(len([t for t in b["tasks"] if not t["done"]]), 1)

    def test_bad_triage_falls_back(self):
        prof = self.mk()
        self.step(prof)
        g, b = self.step(prof, lambda b: (self.launched(b), finish(b, "t-0001-1", "no sé")))
        self.assertTrue(any(l["kind"] == "exception" for l in g["log"]))
        self.assertEqual(len([n for n in g["nodes"].values() if n["kind"] == "bug"]), 4)

    def test_validate(self):
        self.assertTrue(graph.validate({"graph": {"max_depht": 2}}))
        self.assertTrue(graph.validate({"graph": {"done": "x"}}))
        self.assertFalse(graph.validate({"graph": {"max_depth": 2, "done": "ratio"}}))


if __name__ == "__main__":
    unittest.main()
