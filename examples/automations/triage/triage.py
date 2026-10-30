#!/usr/bin/env python3
import json
import os
import sys

RULES = (("bug", ("error", "falla", "crash", "bug", "roto", "no funciona")),
         ("seguridad", ("token", "secreto", "vulnerab", "xss", "inyección")),
         ("docs", ("docs", "documentación", "readme", "typo")))


def classify(text):
    text = text.lower()
    for kind, words in RULES:
        if any(w in text for w in words):
            return kind
    return "pregunta"


def main():
    path = os.environ.get("CHOPSHOP_EVENT_FILE")
    env = {}
    if path:
        with open(path, encoding="utf-8") as f:
            env = json.load(f) or {}
    body = env.get("body") or {}
    if not body:
        print(json.dumps({"type": "triage.result", "severity": "info", "body": {"summary": "sin issue que clasificar"}}))
        return 0
    kind = classify("%s %s" % (body.get("title") or "", body.get("text") or ""))
    print("clasificando %s#%s" % (body.get("repo"), body.get("number")), file=sys.stderr)
    print(json.dumps({
        "type": "triage.result",
        "severity": "warn" if kind == "seguridad" else "notice",
        "needs": "bot",
        "subject": {"kind": "issue", "id": "%s#%s" % (body.get("repo"), body.get("number")), "title": body.get("title"),
                    "url": body.get("url")},
        "body": {"repo": body.get("repo"), "number": body.get("number"), "kind": kind,
                 "priority": "alta" if kind in ("bug", "seguridad") else "normal",
                 "suggest": "chopshop fanout %s --task %s" % (env.get("project") or "<proyecto>", json.dumps(body.get("title") or ""))},
    }, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    sys.exit(main())
