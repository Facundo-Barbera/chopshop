"""Lector de un subconjunto de YAML (stdlib, sin PyYAML): mapas, listas, escalares,
listas en línea [a, b], bloques | y >, comentarios #. Suficiente para perfiles y tasks.yaml."""
import json
import re

_KEY = re.compile(r'^(?P<k>"[^"]*"|\'[^\']*\'|[^\s\-\[\{#"\'][^:#]*?|-[^\s][^:#]*?)\s*:(?:\s+(?P<v>.*)|\s*)$')


class YamlError(ValueError):
    pass


def _strip_comment(s):
    q = None
    for i, c in enumerate(s):
        if q:
            if c == q:
                q = None
        elif c in "\"'":
            q = c
        elif c == "#" and (i == 0 or s[i - 1] in " \t"):
            return s[:i].rstrip()
    return s.rstrip()


def _split_inline(s):
    out, cur, q, depth = [], "", None, 0
    for c in s:
        if q:
            cur += c
            if c == q:
                q = None
        elif c in "\"'":
            q = c
            cur += c
        elif c in "[{":
            depth += 1
            cur += c
        elif c in "]}":
            depth -= 1
            cur += c
        elif c == "," and depth == 0:
            out.append(cur)
            cur = ""
        else:
            cur += c
    if cur.strip():
        out.append(cur)
    return out


def scalar(s):
    s = s.strip()
    if s == "" or s in ("~", "null", "Null"):
        return None
    if s in ("true", "True"):
        return True
    if s in ("false", "False"):
        return False
    if s[0] == '"' and s[-1] == '"' and len(s) >= 2:
        try:
            return json.loads(s)
        except ValueError:
            return s[1:-1]
    if s[0] == "'" and s[-1] == "'" and len(s) >= 2:
        return s[1:-1].replace("''", "'")
    if s[0] == "[" and s[-1] == "]":
        return [scalar(x) for x in _split_inline(s[1:-1])]
    if s[0] == "{" and s[-1] == "}":
        d = {}
        for part in _split_inline(s[1:-1]):
            k, _, v = part.partition(":")
            d[k.strip()] = scalar(v)
        return d
    if re.fullmatch(r"-?\d+", s):
        return int(s)
    if re.fullmatch(r"-?\d+\.\d+", s):
        return float(s)
    return s


class _P:
    def __init__(self, text):
        self.raw = text.splitlines()
        self.i = 0

    def _peek(self):
        while self.i < len(self.raw):
            line = self.raw[self.i]
            body = _strip_comment(line)
            if body.strip() == "":
                self.i += 1
                continue
            if "\t" in line[: len(line) - len(line.lstrip())]:
                raise YamlError("línea %d: tabs no permitidos" % (self.i + 1))
            return len(line) - len(line.lstrip(" ")), body.strip()
        return None

    def block(self, indent):
        pk = self._peek()
        if pk is None:
            return None
        ind, txt = pk
        if txt == "-" or txt.startswith("- "):
            return self.seq(ind)
        return self.mapping(ind)

    def seq(self, indent):
        out = []
        while True:
            pk = self._peek()
            if pk is None or pk[0] != indent or not (pk[1] == "-" or pk[1].startswith("- ")):
                break
            rest = pk[1][1:].strip()
            if rest == "":
                self.i += 1
                nxt = self._peek()
                out.append(self.block(nxt[0]) if nxt and nxt[0] > indent else None)
            elif _KEY.match(rest) and not rest.startswith(("[", "{")):
                # elemento mapa: reescribe la línea como si estuviera indentada tras el guion
                line = self.raw[self.i]
                n = len(line) - len(line.lstrip(" "))
                after = line.lstrip(" ")[1:]
                off = n + 1 + (len(after) - len(after.lstrip(" ")))
                self.raw[self.i] = " " * off + after.lstrip(" ")
                out.append(self.mapping(off))
            else:
                self.i += 1
                out.append(scalar(rest))
        return out

    def mapping(self, indent):
        out = {}
        while True:
            pk = self._peek()
            if pk is None or pk[0] != indent:
                if pk is not None and pk[0] > indent:
                    raise YamlError("línea %d: indentación inesperada" % (self.i + 1))
                break
            m = _KEY.match(pk[1])
            if not m or pk[1].startswith("- "):
                if pk[1].startswith("- "):
                    break
                raise YamlError("línea %d: se esperaba 'clave: valor': %r" % (self.i + 1, pk[1]))
            key = scalar(m.group("k")) if m.group("k")[0] in "\"'" else m.group("k").strip()
            v = (m.group("v") or "").strip()
            self.i += 1
            if v in ("|", ">", "|-", ">-"):
                lines = []
                while self.i < len(self.raw):
                    ln = self.raw[self.i]
                    if ln.strip() == "":
                        lines.append("")
                        self.i += 1
                        continue
                    if len(ln) - len(ln.lstrip(" ")) <= indent:
                        break
                    lines.append(ln)
                    self.i += 1
                ind0 = min([len(x) - len(x.lstrip(" ")) for x in lines if x.strip()] or [0])
                body = [x[ind0:] for x in lines]
                while body and body[-1] == "":
                    body.pop()
                out[key] = ("\n" if v[0] == "|" else " ").join(body)
            elif v == "":
                nxt = self._peek()
                if nxt and (nxt[0] > indent or (nxt[0] == indent and (nxt[1] == "-" or nxt[1].startswith("- ")))):
                    out[key] = self.block(nxt[0])
                else:
                    out[key] = None
            else:
                out[key] = scalar(v)
        return out


def loads(text):
    p = _P(text)
    v = p.block(0)
    if p._peek() is not None:
        raise YamlError("línea %d: contenido sin interpretar" % (p.i + 1))
    return v


def load(path):
    with open(path, encoding="utf-8") as f:
        return loads(f.read())
