from . import employees, engine, settings, state
from .agent import db

DEFAULT_MAX_THREADS = 2


def max_threads():
    v = (settings.section("agent").get("dispatcher") or {}).get("max_threads")
    return int(v) if v else DEFAULT_MAX_THREADS


def live(st):
    return {t["desk"]: t for b in st.get("batches", {}).values() for t in b.get("tasks", [])
            if t.get("desk") and not t.get("done")}


class Dispatcher:
    def __init__(self, conn, queue, prof, slots=None, create_fn=engine.create_batch, route_fn=engine.route,
                 read_fn=state.read):
        self.conn, self.queue, self.prof, self.slots = conn, queue, prof, slots
        self.create_fn, self.route_fn, self.read_fn = create_fn, route_fn, read_fn

    def free(self, busy):
        return max(0, (self.slots or max_threads()) - len(busy))

    def tick(self):
        busy = live(self.read_fn())
        free = self.free(busy)
        out = []
        for e in employees.listing(self.conn, self.prof):
            if free <= 0:
                break
            if e["id"] in busy or not self.queue.length(e["id"]):
                continue
            q = self.queue.pop(e["id"])
            if not q:
                continue
            extra = db.jload(q.get("extra"), {}) or {}
            item = {"title": q["title"], "prompt": extra.get("prompt") or q["title"], "role": e["role"], "desk": e["id"]}
            host, _cap, notes = self.route_fn(self.prof, 1)
            bid = self.create_fn(self.prof, [item], host, 1, notes)
            out.append({"employee": e["id"], "role": e["role"], "task": q["task"], "batch": bid})
            busy[e["id"]] = q
            free -= 1
        return out
