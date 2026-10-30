import re
import time

from . import events, state, t3

LEVELS = ("auto", "bot", "human")
EVENTS = ("pending_question", "task_done", "task_stalled", "task_failed")
FAILED = {"failed", "cancelled", "interrupted", "rolled_back"}


def rules(prof):
    out = []
    for i, r in enumerate(prof.get("reactions") or []):
        if isinstance(r, dict) and r.get("on") in EVENTS and r.get("level") in LEVELS:
            out.append(dict(r, _i=i))
    return out


def validate(prof):
    errs = []
    for i, r in enumerate(prof.get("reactions") or []):
        if not isinstance(r, dict):
            errs.append("reactions[%d]: se esperaba un mapa" % i)
            continue
        if r.get("on") not in EVENTS:
            errs.append("reactions[%d].on inválido (%s)" % (i, ", ".join(EVENTS)))
        if r.get("level") not in LEVELS:
            errs.append("reactions[%d].level inválido (%s)" % (i, ", ".join(LEVELS)))
        if r.get("match"):
            try:
                re.compile(str(r["match"]))
            except re.error as e:
                errs.append("reactions[%d].match no es regex: %s" % (i, e))
        if r.get("level") in ("bot", "human") and r.get("on") == "pending_question" and not r.get("notify"):
            errs.append("reactions[%d]: nivel %s necesita notify (nombre de suscripción)" % (i, r["level"]))
    return errs


def find(prof, on, text=""):
    hits = []
    for r in rules(prof):
        if r["on"] != on:
            continue
        if r.get("match") and not re.search(str(r["match"]), text or "", re.I):
            continue
        hits.append(r)
    hits.sort(key=lambda r: (LEVELS.index(r["level"]) * -1, r["_i"]))
    return hits[0] if hits else None


def _log(t, level, on, rule, action, note=""):
    t.setdefault("reactions", []).append({"ts": state.now(), "level": level, "on": on, "rule": rule["_i"] if rule else None,
                                          "action": action, "note": note[:200]})
    t["level"] = level


def _notify(st, b, t, rule, level, on, body, adhoc):
    name = rule.get("notify")
    payload = {"level": level, "reaction": on, "batch": b["id"], "task": t["id"], "thread": t.get("threadId"),
               "host": b["host"]}
    payload.update(body)
    if not name:
        return {}
    if name not in st.get("subscriptions", {}):
        return {name: "sin suscripción"}
    _, _, res = events.send(st, "reaction", b["project"], payload, None, only=[name])
    return res


def _settle(hc, b, t):
    t3.call(hc, b["host"], "t3_thread_organize", {"threadId": t["threadId"], "action": "settle"})
    t["settled"] = True


def _new_task(b, t, why):
    n = len(b["tasks"]) + 1
    rec = {"id": "t-%s-%d" % (b["id"][2:], n), "title": t["title"], "prompt": t["prompt"], "issue": t.get("issue"),
           "status": "queued", "threadId": None, "link": None, "t3status": None, "done": False, "notified": [],
           "settled": False, "retry_of": t["id"], "retries": t.get("retries", 0) + 1}
    if t.get("node"):
        rec["node"] = t["node"]
    b["tasks"].append(rec)
    return rec


def on_question(st, b, t, prof, q, hc, log, adhoc, rid):
    t.setdefault("reacted", []).append(rid)
    text = " ".join([q.get("summary") or ""] + [str(o) for o in q.get("options") or []])
    rule = find(prof, "pending_question", text)
    if not rule:
        return False
    lvl = rule["level"]
    body = {"request": rid, "summary": q.get("summary"), "options": q.get("options"),
            "reply": 'chopshop answer %s "<opción>" --by <quién>' % t["id"]}
    if lvl == "auto":
        choice = str(rule.get("choice") or ((q.get("options") or [""])[0]))
        _log(t, "auto", "pending_question", rule, "answer:%s" % choice, q.get("summary") or "")
        events.send(st, "reaction", b["project"], dict(body, level="auto", task=t["id"], action="answer", choice=choice), None, only=[])
        t["_auto_answer"] = {"choice": choice, "request": rid}
        log("reacción auto %s: responder '%s'" % (t["id"], choice))
        return True
    if lvl == "bot":
        res = _notify(st, b, t, rule, "bot", "pending_question", body, adhoc)
        _log(t, "bot", "pending_question", rule, "despertar a %s" % rule.get("notify"), "entrega: %s" % (res or "sin destinatario"))
        t["bot_wait"] = {"request": rid, "since": time.time(), "since_ts": state.now(), "notify": rule.get("notify"),
                         "escalate_after": int(rule.get("escalate_after") or 0), "escalate_to": rule.get("escalate_to"),
                         "delivery": res}
        log("reacción bot %s -> %s %s" % (t["id"], rule.get("notify"), res))
        return False
    res = _notify(st, b, t, rule, "human", "pending_question", body, adhoc)
    _log(t, "human", "pending_question", rule, "escalar a %s" % rule.get("notify"), "entrega: %s" % (res or "sin destinatario"))
    t["escalation"] = {"request": rid, "summary": q.get("summary"), "options": q.get("options"), "since": state.now(),
                       "notify": rule.get("notify"), "status": "open", "delivery": res, "reason": "irreversible o fuera de autonomía"}
    log("reacción HUMANO %s escalada a %s %s" % (t["id"], rule.get("notify"), res))
    return False


def check_waiting(st, b, t, prof, qs_now, adhoc, log):
    bw = t.get("bot_wait")
    if bw and not bw.get("escalated") and bw.get("escalate_after") and time.time() - bw["since"] > bw["escalate_after"] \
            and any(q["request"] == bw["request"] for q in qs_now):
        bw["escalated"] = True
        q = next(q for q in qs_now if q["request"] == bw["request"])
        rule = {"_i": None, "notify": bw.get("escalate_to"), "level": "human"}
        res = _notify(st, b, t, rule, "human", "pending_question", {"request": q["request"], "summary": q["summary"],
                      "options": q["options"], "reason": "el bot no respondió en %ss" % bw["escalate_after"]}, adhoc)
        _log(t, "human", "pending_question", None, "escalar a %s" % bw.get("escalate_to"), "el bot %s no respondió" % bw.get("notify"))
        t["escalation"] = {"request": q["request"], "summary": q["summary"], "options": q["options"], "since": state.now(),
                           "notify": bw.get("escalate_to"), "status": "open", "delivery": res, "reason": "el bot no respondió a tiempo"}
        log("reacción HUMANO %s: el bot no respondió" % t["id"])


def check_resolved(t, qs_now):
    open_ids = {q["request"] for q in qs_now}
    es = t.get("escalation")
    if es and es.get("status") == "open" and es["request"] not in open_ids:
        a = (t.get("answered") or [])[-1:] or [{}]
        es.update(status="resolved", resolved=state.now(), by=a[0].get("by") or "?", choice=a[0].get("choice"))
    bw = t.get("bot_wait")
    if bw and not bw.get("done") and bw["request"] not in open_ids:
        a = (t.get("answered") or [])[-1:] or [{}]
        bw.update(done=True, resolved=state.now(), by=a[0].get("by") or "?", choice=a[0].get("choice"))


def on_progress(st, b, t, th, prof, hc, log, adhoc):
    fp = "%s|%s|%s" % (th.get("status"), th.get("itemCount"), th.get("updatedAt"))
    pend = t.get("pending") or {}
    if pend.get("questions") or pend.get("approvals") or (t.get("escalation") or {}).get("status") == "open" \
            or (t.get("bot_wait") and not t["bot_wait"].get("done")):
        t["fp"], t["progress_at"] = fp, time.time()
        return
    if t.get("fp") != fp:
        t["fp"] = fp
        t["progress_at"] = time.time()
        return
    rule = find(prof, "task_stalled", t.get("title"))
    if not rule or t.get("stall_fired") or th.get("status") == "waiting":
        return
    if time.time() - t.get("progress_at", time.time()) < float(rule["after"] if rule.get("after") is not None else 120):
        return
    t["stall_fired"] = True
    _apply_terminal_rule(st, b, t, rule, "task_stalled", hc, log, adhoc, interrupt=True)


def on_terminal(st, b, t, status, prof, hc, log, adhoc):
    on = "task_done" if status == "completed" else "task_failed"
    rule = find(prof, on, t.get("title"))
    if rule:
        _apply_terminal_rule(st, b, t, rule, on, hc, log, adhoc)


def _apply_terminal_rule(st, b, t, rule, on, hc, log, adhoc, interrupt=False):
    do = rule.get("do") or ("settle" if on == "task_done" else "retry_once")
    lvl = rule["level"]
    try:
        if lvl == "auto" and do == "settle":
            _settle(hc, b, t)
            _log(t, "auto", on, rule, "settle", "hilo marcado settled")
            log("reacción auto %s: settle" % t["id"])
        elif lvl == "auto" and do == "retry_once":
            if interrupt:
                try:
                    t3.call(hc, b["host"], "t3_thread_interrupt", {"threadId": t["threadId"], "reason": "chopshop: sin progreso"})
                except t3.T3Error:
                    pass
                t.update(status="stalled", done=True)
            if t.get("retries", 0) >= 1 or t.get("retry_of"):
                _log(t, "auto", on, rule, "retry_once:agotado", "ya se reintentó una vez; se escala a humano")
                t["escalation"] = {"request": None, "summary": "«%s» falló otra vez tras el reintento" % t["title"], "options": [],
                                   "since": state.now(), "status": "open", "reason": "reintento agotado", "notify": rule.get("notify")}
                _notify(st, b, t, rule, "human", on, {"summary": t["escalation"]["summary"]}, adhoc)
                return
            nt = _new_task(b, t, on)
            t["retried_by"] = nt["id"]
            if not t["done"]:
                t["done"] = True
            try:
                _settle(hc, b, t)
            except t3.T3Error:
                pass
            _log(t, "auto", on, rule, "retry_once", "nueva tarea %s (hilo viejo settled)" % nt["id"])
            log("reacción auto %s: reintento único -> %s" % (t["id"], nt["id"]))
        else:
            res = _notify(st, b, t, rule, lvl, on, {"summary": t["title"]}, adhoc)
            _log(t, lvl, on, rule, do, "entrega: %s" % (res or "sin destinatario"))
            if lvl == "human":
                t["escalation"] = {"request": None, "summary": t["title"], "options": [], "since": state.now(),
                                   "status": "open", "reason": on, "notify": rule.get("notify")}
    except t3.T3Error as e:
        _log(t, lvl, on, rule, do + ":error", str(e))
        log("! reacción %s: %s" % (t["id"], str(e)[:160]))
