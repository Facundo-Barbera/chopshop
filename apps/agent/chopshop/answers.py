class InvalidChoice(ValueError):
    pass


def _value(o):
    return o.get("value") or o["label"]


def resolve(q, choice):
    opts = q.get("options", [])
    picks = [c.strip() for c in choice.split(",")] if q.get("multiSelect") else [choice]
    res = []
    for c in picks:
        if c.isdigit() and 1 <= int(c) <= len(opts):
            res.append(_value(opts[int(c) - 1]))
            continue
        m = [o for o in opts if o["label"].lower() == c.lower() or (o.get("value") or "").lower() == c.lower()]
        if m:
            res.append(_value(m[0]))
            continue
        if opts and q.get("allowCustomAnswer") is False:
            raise InvalidChoice("'%s' no es una opción válida" % c)
        res.append(c)
    return res if q.get("multiSelect") else res[0]


def resolve_all(questions, choice):
    if not questions:
        raise InvalidChoice("la petición no trae preguntas")
    if isinstance(choice, dict):
        by_id = {q["id"]: q for q in questions}
        unknown = [k for k in choice if k not in by_id]
        if unknown or len(choice) != len(questions):
            raise InvalidChoice("respuestas no coinciden con las preguntas (%s)" % ", ".join(sorted(by_id)))
        return {k: resolve(by_id[k], str(v)) for k, v in choice.items()}
    if len(questions) != 1:
        raise InvalidChoice("la petición tiene %d preguntas; pasa choice como {id: elección}" % len(questions))
    return {questions[0]["id"]: resolve(questions[0], str(choice))}
