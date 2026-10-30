from . import employees, engine, profile, settings, state, t3
from .agent import db

DEFAULT_MAX_THREADS = 2
SETTLE_TRIES = 3


def max_threads():
    v = (settings.section("agent").get("dispatcher") or {}).get("max_threads")
    return int(v) if v else DEFAULT_MAX_THREADS


def live(st):
    return {t["desk"]: t for b in st.get("batches", {}).values() for t in b.get("tasks", [])
            if t.get("desk") and not t.get("done")}


def settle_thread(host, thread_id):
    t3.call(profile.hosts()[host], host, "t3_thread_organize", {"threadId": thread_id, "action": "settle"})


def launch(batch_id):
    engine.tick(batch_id, log=lambda *_: None)


def outcome(t):
    if t.get("status") == "launched" and t.get("t3status") == "completed":
        return "done", None
    why = t.get("t3status") if t.get("status") == "launched" else t.get("status")
    err = t.get("last_error") or t.get("skip_reason")
    return "failed", ("%s: %s" % (why, err) if err else str(why))[:300]


class Dispatcher:
    def __init__(self, conn, queue, prof, slots=None, create_fn=engine.create_batch, route_fn=engine.route,
                 read_fn=state.read, settle_fn=settle_thread, launch_fn=launch, lock_fn=state.locked):
        self.conn, self.queue, self.prof, self.slots = conn, queue, prof, slots
        self.create_fn, self.route_fn, self.read_fn = create_fn, route_fn, read_fn
        self.settle_fn, self.launch_fn, self.lock_fn = settle_fn, launch_fn, lock_fn

    def close(self):
        out = []
        with self.lock_fn() as st:
            for b in st.get("batches", {}).values():
                for t in b.get("tasks", []):
                    if not t.get("desk") or not t.get("done") or t.get("closed"):
                        continue
                    if t.get("threadId") and not t.get("settled"):
                        try:
                            self.settle_fn(b["host"], t["threadId"])
                            t["settled"] = True
                        except t3.T3Error as e:
                            t["settle_tries"] = t.get("settle_tries", 0) + 1
                            t["last_error"] = str(e)[:300]
                            if t["settle_tries"] < SETTLE_TRIES:
                                continue
                    st_, why = outcome(t)
                    if t.get("threadId") and not t.get("settled"):
                        why = ("%s; settle: %s" % (why, t["last_error"]) if why else "settle: " + t["last_error"])[:300]
                    if t.get("qtask"):
                        self.queue.finish(t["qtask"], st_, why)
                    t["closed"] = True
                    out.append({"employee": t["desk"], "task": t.get("qtask"), "state": st_, "reason": why,
                                "settled": bool(t.get("settled")), "thread_id": t.get("threadId")})
        return out

    def free(self, busy):
        return max(0, (self.slots or max_threads()) - len(busy))

    def tick(self):
        self.close()
        return self.dispatch()

    def dispatch(self):
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
            item = {"title": q["title"], "prompt": extra.get("prompt") or q["title"], "role": e["role"], "desk": e["id"],
                    "qtask": q["task"]}
            host, _cap, notes = self.route_fn(self.prof, 1)
            bid = self.create_fn(self.prof, [item], host, 1, notes)
            if self.launch_fn:
                self.launch_fn(bid)
            out.append({"employee": e["id"], "role": e["role"], "task": q["task"], "batch": bid})
            busy[e["id"]] = q
            free -= 1
        return out
