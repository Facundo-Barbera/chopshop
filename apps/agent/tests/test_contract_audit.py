import importlib.util
import json
import os
import shutil
import tempfile
import unittest

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__)))))
SPEC = importlib.util.spec_from_file_location("contract_audit", os.path.join(ROOT, "tools", "contract_audit.py"))
audit = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(audit)

BASE = "https://schemas.test/"
COMMON = {"$id": BASE + "common.schema.json",
          "$defs": {"name": {"type": "string", "pattern": "^[a-z]{1,8}$"}, "n": {"type": "integer", "minimum": 0}}}
THING = {"$id": BASE + "dom/thing.schema.json", "type": "object", "additionalProperties": False,
         "required": ["name", "kind"],
         "properties": {"name": {"$ref": "../common.schema.json#/$defs/name"}, "kind": {"enum": ["a", "b", None]},
                        "tags": {"type": "array", "items": {"$ref": "../common.schema.json#/$defs/name"},
                                 "uniqueItems": True, "maxItems": 2},
                        "count": {"$ref": "../common.schema.json#/$defs/n"},
                        "extra": {"type": "object", "additionalProperties": {"type": "boolean"}},
                        "either": {"oneOf": [{"type": "string"}, {"type": "null"}]},
                        "flag": {"const": True}}}


def errors(inst):
    s = audit.MiniSchemas({COMMON["$id"]: COMMON, THING["$id"]: THING})
    return s.errors(THING, inst, THING["$id"])


class MiniValidatorTest(unittest.TestCase):
    def test_valid(self):
        self.assertEqual(errors({"name": "ana", "kind": None, "tags": ["x", "y"], "count": 3, "extra": {"k": False},
                                 "either": None, "flag": True}), [])

    def test_required_and_additional(self):
        msgs = [m for _, m in errors({"name": "ana", "other": 1})]
        self.assertIn("falta kind", msgs)
        self.assertIn("propiedad no permitida: other", msgs)

    def test_types_pattern_enum(self):
        self.assertTrue(errors({"name": "Ana", "kind": "a"}))
        self.assertTrue(errors({"name": "ana", "kind": "c"}))
        self.assertTrue(errors({"name": "ana", "kind": "a", "count": True}))
        self.assertTrue(errors({"name": "ana", "kind": "a", "count": 1.5}))
        self.assertTrue(errors({"name": "ana", "kind": "a", "count": -1}))
        self.assertTrue(errors({"name": "ana", "kind": "a", "flag": 1}))

    def test_items_and_additional_schema(self):
        self.assertTrue(errors({"name": "ana", "kind": "a", "tags": ["x", "X"]}))
        self.assertTrue(errors({"name": "ana", "kind": "a", "tags": ["x", "x"]}))
        self.assertTrue(errors({"name": "ana", "kind": "a", "tags": ["x", "y", "z"]}))
        self.assertTrue(errors({"name": "ana", "kind": "a", "extra": {"k": "no"}}))

    def test_one_of(self):
        self.assertTrue(errors({"name": "ana", "kind": "a", "either": 3}))
        s = audit.MiniSchemas({})
        self.assertTrue(s.errors({"oneOf": [{"type": "integer"}, {"type": "number"}]}, 3, BASE))
        self.assertEqual(s.errors({"oneOf": [{"type": "integer"}, {"type": "number"}]}, 3.5, BASE), [])

    def test_lint(self):
        s = audit.MiniSchemas({COMMON["$id"]: COMMON})
        bad = {"$id": BASE + "x.schema.json", "type": "object", "properties": {
            "a": {"type": "string", "format": "email"}, "b": {"$ref": "common.schema.json#/$defs/missing"}}}
        msgs = [m for _, m in s.lint(bad, bad["$id"])]
        self.assertIn("palabra clave no soportada: format", msgs)
        self.assertIn("$ref sin resolver: common.schema.json#/$defs/missing", msgs)
        self.assertEqual(s.lint(THING, THING["$id"]), [])


class BackendAuditTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, self.tmp)

    def write(self, rel, data):
        p = os.path.join(self.tmp, rel)
        os.makedirs(os.path.dirname(p), exist_ok=True)
        with open(p, "w") as f:
            json.dump(data, f)

    def test_repo_contracts(self):
        failures, summary = audit.backend_audit()
        self.assertEqual(failures, [])
        self.assertTrue(summary.startswith("S1: "))
        for name in ("idn/auth-login.post.request", "idn/auth-login.post.response", "wsp/workspaces-id.patch.request",
                     "cty/state.get.response", "hub/ws-hello", "hub/ws-sync", "hub/ws-sync-ack", "error"):
            self.assertTrue(os.path.exists(os.path.join(audit.BACKEND, name + ".schema.json")), name)

    def test_detects_bad_fixtures(self):
        self.write("common.schema.json", COMMON)
        self.write("dom/thing.schema.json", THING)
        self.write("dom/orphan.schema.json", {"$id": BASE + "dom/orphan.schema.json", "type": "object"})
        self.write("dom/fixtures/thing.json", {"name": "ana", "kind": "a"})
        self.write("dom/fixtures/thing.broken.json", {"name": "ana"})
        self.write("dom/fixtures/unknown.json", {})
        self.write("dom/fixtures/invalid/thing.passes.json", {"name": "ana", "kind": "b"})
        self.write("dom/fixtures/invalid/thing.fails.json", {"name": "ana", "kind": "z"})
        failures, summary = audit.backend_audit(self.tmp)
        joined = "\n".join(failures)
        self.assertIn("dom/fixtures/thing.broken.json: $: falta kind", joined)
        self.assertIn("dom/fixtures/unknown.json: no hay schema", joined)
        self.assertIn("dom/fixtures/invalid/thing.passes.json: es inválida", joined)
        self.assertIn("S1 schema dom/orphan: sin fixture válida", joined)
        self.assertNotIn("thing.fails", joined)
        self.assertEqual(len(failures), 4)
        self.assertEqual(summary, "S1: 3 schemas, 2 fixtures válidas, 2 inválidas")


if __name__ == "__main__":
    unittest.main()
