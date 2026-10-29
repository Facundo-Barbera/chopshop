"""API de estructura de la oficina para los bots (chopshop.agent.structure + `GET/PUT /office/<proyecto>`): validación como
`profile check`, reescritura solo de los bloques office/rack, escritorios retirados (nunca borrados), reactivación explícita,
`base_rev`, `office.changed` y permisos (solo escritura autenticada)."""
import copy
import json
import os
import sys
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from chopshop import home, miniyaml  # noqa: E402
from chopshop.agent import db, events, structure as S  # noqa: E402
from test_agent_server import TOKEN, ServerBase  # noqa: E402

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "..", ".."))
EXAMPLE = os.path.join(ROOT, "examples", "profiles", "awesome-gb.example.yaml")
HEAD = "# perfil local (comentario que debe sobrevivir)\nproject: awesome-gb\nrepo: <org>/<repo-principal>\n"


def example():
    return miniyaml.load(EXAMPLE)


class TestDump(unittest.TestCase):
    def test_roundtrip_example_blocks(self):
        ex = example()
        for key in ("office", "rack"):
            text = "%s:\n%s\n" % (key, "\n".join(S.dump(ex[key], 2)))
            self.assertEqual(miniyaml.loads(text), {key: ex[key]}, text)

    def test_replace_blocks_keeps_rest(self):
        text = HEAD + "office:\n  company: Vieja\n  floors: []\n\n# notas\nrack:\n  repos: []\nmodel: a/b\n"
        out = S.replace_blocks(text, {"office": {"company": "Nueva", "floors": [{"rooms": [{"role": "be", "desks": 2}]}]}})
        self.assertTrue(out.startswith(HEAD))
        self.assertIn("\n\n# notas\nrack:\n  repos: []\nmodel: a/b\n", out)
        d = miniyaml.loads(out)
        self.assertEqual(d["office"], {"company": "Nueva", "floors": [{"rooms": [{"role": "be", "desks": 2}]}]})
        self.assertEqual((d["model"], d["rack"]), ("a/b", {"repos": []}))
        out2 = S.replace_blocks(HEAD, {"rack": {"actors": {"grok-x": {"kind": "bot"}}}})
        self.assertEqual(miniyaml.loads(out2)["rack"], {"actors": {"grok-x": {"kind": "bot"}}})

    def test_bad_keys_rejected(self):
        with self.assertRaises(S.StructureError):
            S.dump({'a"b': 1})


class ApiBase(ServerBase):
    def setUp(self):
        super().setUp()
        self.start()
        os.environ["CHOPSHOP_CONFIG"] = os.path.join(self.tmp, "config.toml")     # nunca el config real de la máquina
        with open(os.environ["CHOPSHOP_CONFIG"], "w") as f:
            f.write("")
        os.makedirs(home.profiles_dir(), exist_ok=True)
        self.path = os.path.join(home.profiles_dir(), "awesome-gb.yaml")
        with open(EXAMPLE, encoding="utf-8") as f:
            self.write(f.read().replace("project: awesome-gb\n", "# comentario local\nproject: awesome-gb\n"))
        os.chmod(self.path, 0o600)
        self.svc.office.reload()                    # como el arranque del servicio: la oficina ya conoce el perfil
        with db.tx():
            self.base_seq = self.conn.execute("SELECT COALESCE(MAX(seq),0) FROM events").fetchone()[0]

    def tearDown(self):
        os.environ.pop("CHOPSHOP_CONFIG", None)

    def write(self, text):
        with open(self.path, "w", encoding="utf-8") as f:
            f.write(text)

    def text(self):
        with open(self.path, encoding="utf-8") as f:
            return f.read()

    def put(self, body, project="awesome-gb", **kw):
        return self.req("PUT", "/office/" + project, body, **kw)

    def office(self):
        return copy.deepcopy(example()["office"])

    def last_changed(self):
        with db.tx():
            row = self.conn.execute("SELECT seq FROM events WHERE type='office.changed' AND seq>? ORDER BY seq DESC LIMIT 1",
                                    (self.base_seq,)).fetchone()
        return events.to_envelope(self.conn.execute("SELECT * FROM events WHERE seq=?", (row["seq"],)).fetchone()) if row else None


class TestOfficeApi(ApiBase):
    def test_get(self):
        st, body, _ = self.get("/office/awesome-gb")
        self.assertEqual(st, 200, body)
        self.assertEqual(body["office"], example()["office"])
        self.assertEqual(body["rev"], S.rev(self.text()))
        self.assertEqual(body["limits"]["floors_per_project"], 4)
        self.assertEqual(len([d for f in body["structure"]["floors"] for r in f["rooms"] for d in r["desks"]]), 10)
        self.assertEqual(self.get("/office/no-existe")[0], 404)
        self.assertEqual(self.get("/office/..%2Fx")[0], 400)

    def test_reorganize_retires_never_deletes(self):
        o = self.office()
        o["floors"][0]["rooms"] = [{"role": "triage", "desks": 1, "permanent": True}, {"role": "backend", "desks": 2},
                                   {"role": "frontend", "desks": 4}]
        st, body, _ = self.put({"office": o, "by": "Grok · Facundo"})
        self.assertEqual(st, 200, body)
        self.assertTrue(body["changed"])
        self.assertEqual(body["diff"], {"added": ["awesome-gb/0/frontend/3"],
                                        "retired": ["awesome-gb/0/backend/2", "awesome-gb/0/backend/3"], "reactivated": []})
        be = next(r for r in body["office"]["floors"][0]["rooms"] if r["role"] == "backend")
        self.assertEqual([(d["slot"], d["retired"]) for d in be["desks"]], [(0, False), (1, False), (2, True), (3, True)])
        # el perfil: solo cambió office; comentario, rack y resto intactos; modo conservado
        text = self.text()
        self.assertTrue(text.startswith("# Ejemplo de perfil"))
        self.assertIn("# comentario local\nproject: awesome-gb\n", text)
        d = miniyaml.loads(text)
        self.assertEqual((d["office"], d["rack"]), (o, example()["rack"]))
        self.assertEqual(os.stat(self.path).st_mode & 0o777, 0o600)
        # sobre office.changed válido, con el bot como autor y los retirados dentro
        env = self.last_changed()
        self.assertEqual((env["seq"], env["subject"], env["body"]["by"]), (body["seq"], {"kind": "office", "id": "awesome-gb"},
                                                                         "Grok · Facundo"))
        self.assertEqual(env["body"]["floors"], body["office"]["floors"])
        self.assertEqual(env["body"]["diff"], body["diff"])
        # un segundo PUT que no menciona los retirados los sigue mostrando retirados (se recuerdan en el agente)
        o["floors"][0]["rooms"][2]["desks"] = 3
        st, body, _ = self.put({"office": o, "by": "Grok · Juan Manuel"})
        self.assertEqual(st, 200, body)
        be = next(r for r in body["office"]["floors"][0]["rooms"] if r["role"] == "backend")
        self.assertEqual([d["retired"] for d in be["desks"]], [False, False, True, True])
        self.assertEqual(body["diff"]["retired"], ["awesome-gb/0/frontend/3"])
        self.assertEqual(self.get("/office/awesome-gb")[1]["structure"], body["office"])

    def test_reactivation_requires_explicit_list(self):
        o = self.office()
        o["floors"][1]["rooms"][0]["desks"] = 1
        self.assertEqual(self.put({"office": o, "by": "bot"})[0], 200)
        o["floors"][1]["rooms"][0]["desks"] = 2
        before = self.text()
        st, body, _ = self.put({"office": o, "by": "bot"})
        self.assertEqual(st, 409, body)
        self.assertEqual(body["problems"], ["awesome-gb/1/docs/1 está retirado"])
        self.assertEqual(self.text(), before)
        st, body, _ = self.put({"office": o, "by": "facundo", "reactivate": ["awesome-gb/1/docs/1"]})
        self.assertEqual((st, body["diff"]["reactivated"]), (200, ["awesome-gb/1/docs/1"]), body)
        self.assertFalse(any(d["retired"] for f in body["office"]["floors"] for r in f["rooms"] for d in r["desks"]))

    def test_validation_like_profile_check(self):
        before = self.text()
        o = self.office()
        o["floors"] = o["floors"] * 3                              # 6 pisos
        st, body, _ = self.put({"office": o, "by": "bot"})
        self.assertEqual(st, 400)
        self.assertTrue(any("máximo 4 por proyecto" in p for p in body["problems"]), body)
        o = self.office()
        o["floors"][0]["rooms"][1]["desks"] = 9
        o["roles"]["fantasma"] = {"match": {"title": "("}}
        st, body, _ = self.put({"office": o, "by": "bot"})
        self.assertEqual(st, 400)
        self.assertEqual(len(body["problems"]), 3, body)               # desks, rol sin departamento, regex
        self.assertEqual(self.put({"office": self.office(), "rack": {"repos": [{"repo": "sin-barra"}]}, "by": "bot"})[0], 400)
        for bad in ({"by": "bot"}, {"office": [], "by": "bot"}, {"office": self.office()},
                    {"office": self.office(), "by": "bot", "reactivate": "x"}):
            self.assertEqual(self.put(bad)[0], 400, bad)
        self.assertEqual(self.text(), before)
        self.assertIsNone(self.last_changed())

    def test_building_cap_counts_other_profiles(self):
        with open(os.path.join(home.profiles_dir(), "otro.yaml"), "w") as f:
            f.write("project: otro\noffice:\n  company: Awesome GB\n  floors:\n" +
                    "".join("    - rooms:\n        - {role: be, desks: 1}\n" for _ in range(4)))
        for n in range(3):
            with open(os.path.join(home.profiles_dir(), "otro%d.yaml" % n), "w") as f:
                f.write("project: otro%d\noffice:\n  company: Awesome GB\n  floors:\n" % n +
                        "".join("    - rooms:\n        - {role: be, desks: 1}\n" for _ in range(4)))
        o = self.office()
        o["floors"].append({"rooms": [{"role": "qa", "desks": 1}]})
        st, body, _ = self.put({"office": o, "by": "bot"})
        self.assertEqual(st, 400)
        self.assertIn("edificio Awesome GB", body["problems"][0])

    def test_base_rev_and_noop(self):
        rev0 = self.get("/office/awesome-gb")[1]["rev"]
        st, body, _ = self.put({"office": self.office(), "rack": example()["rack"], "by": "bot", "base_rev": rev0})
        self.assertEqual((st, body["changed"], body["seq"]), (200, False, None), body)    # sin cambios: ni escritura ni sobre
        o = self.office()
        o["half_life"] = "45m"
        self.assertEqual(self.put({"office": o, "by": "bot", "base_rev": rev0})[0], 200)
        st, body, _ = self.put({"office": self.office(), "by": "bot", "base_rev": rev0})
        self.assertEqual(st, 409, body)
        self.assertEqual(miniyaml.loads(self.text())["office"]["half_life"], "45m")

    def test_unrepresentable_text_is_rejected_without_writing(self):
        before = self.text()
        o = self.office()
        o["floors"][0]["name"] = 'Pro"ducto #1'
        st, body, _ = self.put({"office": o, "by": "bot"})
        self.assertEqual(st, 400, body)                                 # miniyaml cortaría en « #1»: no se escribe
        self.assertEqual(self.text(), before)
        o["floors"][0]["name"] = "Producto: ñ - #2 \\ 'x'"
        self.assertEqual(self.put({"office": o, "by": "bot"})[0], 200)
        self.assertEqual(miniyaml.loads(self.text())["office"]["floors"][0]["name"], o["floors"][0]["name"])

    def test_no_delete_or_other_methods(self):
        self.assertEqual(self.req("DELETE", "/office/awesome-gb")[0], 405)
        self.assertEqual(self.post("/office/awesome-gb", {"office": {}, "by": "x"})[0], 405)
        st, _, _ = self.req("PUT", "/office/awesome-gb", raw=b"{}", headers={"Content-Type": "text/plain"})
        self.assertEqual(st, 403)


class TestOfficeAuth(ApiBase):
    def start(self, **over):                                    # ApiBase arranca con trust_local=False
        if self.svc is not None:
            return self.svc
        return super().start(**dict(over, auth="tailscale+token", trust_local=False))

    def test_put_requires_owner_with_credential(self):
        body = {"office": self.office(), "by": "bot"}
        self.ts.logins["127.0.0.1"] = "lector@github"
        self.assertEqual(self.put(body, headers={"Authorization": "Bearer " + TOKEN})[0], 403)    # solo lectura
        self.assertEqual(self.get("/office/awesome-gb", headers={"Authorization": "Bearer " + TOKEN})[0], 200)
        self.ts.logins["127.0.0.1"] = "yo@github"
        self.svc.auth._whois.clear()
        self.assertEqual(self.put(body)[0], 401)                                                   # sin credencial
        self.assertEqual(self.put(body, headers={"Authorization": "Bearer otro"})[0], 401)
        self.ts.logins["127.0.0.1"] = "intruso@github"
        self.svc.auth._whois.clear()
        self.assertEqual(self.put(body, headers={"Authorization": "Bearer " + TOKEN})[0], 403)
        self.ts.logins["127.0.0.1"] = "yo@github"
        self.svc.auth._whois.clear()
        st, res, _ = self.put(body, headers={"Authorization": "Bearer " + TOKEN})
        self.assertEqual((st, res["ok"]), (200, True), res)


if __name__ == "__main__":
    unittest.main()
