"""Genera Resources/ui-fixture.state.json: el fold de ui-fixture.jsonl con el reductor del agente (projection.py).

    python3 apps/mac/Tests/ChopshopNativeTests/tools/make_golden.py <ruta a apps/agent>

Los tests de Swift (LiveStateTests) comprueban que LiveState.fold da lo mismo. Regenéralo si cambia el contrato o el fixture."""
import json
import os
import sys

agent = os.path.abspath(sys.argv[1] if len(sys.argv) > 1 else os.path.join(os.path.dirname(__file__), "../../../../agent"))
sys.path.insert(0, agent)
from chopshop.agent import projection  # noqa: E402

res = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "Resources")
with open(os.path.join(res, "ui-fixture.jsonl"), encoding="utf-8") as f:
    envs = [json.loads(line) for line in f if line.strip()]
state = projection.fold(envs)
with open(os.path.join(res, "ui-fixture.state.json"), "w", encoding="utf-8") as f:
    json.dump(state, f, ensure_ascii=False, indent=1, sort_keys=True)
    f.write("\n")
print("ok: %d sobres, head_seq %d" % (len(envs), state["head_seq"]))
