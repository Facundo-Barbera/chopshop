import re


class TomlError(ValueError):
    pass


def loads(text):
    try:
        import tomllib
        try:
            return tomllib.loads(text)
        except tomllib.TOMLDecodeError as e:
            raise TomlError(str(e))
    except ImportError:
        return _Parser(text).parse()


def load(path):
    with open(path, encoding="utf-8") as f:
        return loads(f.read())


_BARE = re.compile(r"[A-Za-z0-9_-]+")
_ESC = {"b": "\b", "t": "\t", "n": "\n", "f": "\f", "r": "\r", '"': '"', "\\": "\\"}


class _Parser:
    def __init__(self, text):
        self.s = text
        self.i = 0
        self.line = 1

    def err(self, msg):
        raise TomlError("línea %d: %s" % (self.s.count("\n", 0, self.i) + 1, msg))

    def peek(self):
        return self.s[self.i] if self.i < len(self.s) else ""

    def skip_ws(self, newlines=False):
        while self.i < len(self.s):
            c = self.s[self.i]
            if c in " \t" or (newlines and c in "\r\n"):
                self.i += 1
            elif c == "#" and newlines:
                while self.i < len(self.s) and self.s[self.i] != "\n":
                    self.i += 1
            else:
                break

    def end_of_line(self):
        self.skip_ws()
        if self.peek() == "#":
            while self.i < len(self.s) and self.s[self.i] != "\n":
                self.i += 1
        if self.peek() not in ("", "\n", "\r"):
            self.err("texto inesperado: %r" % self.s[self.i:self.i + 12])

    def key(self):
        self.skip_ws()
        c = self.peek()
        if c == '"':
            return self.basic_string()
        if c == "'":
            return self.literal_string()
        m = _BARE.match(self.s, self.i)
        if not m:
            self.err("clave inválida")
        self.i = m.end()
        return m.group()

    def dotted(self):
        parts = [self.key()]
        while True:
            self.skip_ws()
            if self.peek() == ".":
                self.i += 1
                parts.append(self.key())
            else:
                return parts

    def basic_string(self):
        self.i += 1
        out = []
        while True:
            c = self.peek()
            if c == "" or c == "\n":
                self.err("cadena sin cerrar")
            self.i += 1
            if c == '"':
                return "".join(out)
            if c == "\\":
                e = self.peek()
                self.i += 1
                if e in _ESC:
                    out.append(_ESC[e])
                elif e in "uU":
                    n = 4 if e == "u" else 8
                    out.append(chr(int(self.s[self.i:self.i + n], 16)))
                    self.i += n
                else:
                    self.err("escape inválido \\%s" % e)
            else:
                out.append(c)

    def literal_string(self):
        j = self.s.find("'", self.i + 1)
        if j < 0 or "\n" in self.s[self.i:j]:
            self.err("cadena literal sin cerrar")
        v = self.s[self.i + 1:j]
        self.i = j + 1
        return v

    def value(self):
        self.skip_ws()
        c = self.peek()
        if c == '"':
            if self.s.startswith('"""', self.i):
                self.err("cadenas multilínea no soportadas")
            return self.basic_string()
        if c == "'":
            return self.literal_string()
        if c == "[":
            return self.array()
        if c == "{":
            return self.inline()
        m = re.compile(r"[^\s,\]}#]+").match(self.s, self.i)
        if not m:
            self.err("valor vacío")
        tok = m.group()
        self.i = m.end()
        if tok == "true":
            return True
        if tok == "false":
            return False
        try:
            t = tok.replace("_", "")
            if re.fullmatch(r"[+-]?(0|[1-9]\d*)", t):
                return int(t)
            if t.lower().startswith(("0x", "0o", "0b")):
                return int(t, 0)
            return float(t)
        except ValueError:
            self.err("valor inválido: %r" % tok)

    def array(self):
        self.i += 1
        out = []
        while True:
            self.skip_ws(newlines=True)
            if self.peek() == "]":
                self.i += 1
                return out
            out.append(self.value())
            self.skip_ws(newlines=True)
            if self.peek() == ",":
                self.i += 1
            elif self.peek() != "]":
                self.err("se esperaba , o ]")

    def inline(self):
        self.i += 1
        out = {}
        while True:
            self.skip_ws()
            if self.peek() == "}":
                self.i += 1
                return out
            ks = self.dotted()
            self.skip_ws()
            if self.peek() != "=":
                self.err("se esperaba =")
            self.i += 1
            _set(out, ks, self.value())
            self.skip_ws()
            if self.peek() == ",":
                self.i += 1
            elif self.peek() != "}":
                self.err("se esperaba , o }")

    def parse(self):
        root = {}
        cur = root
        while True:
            self.skip_ws(newlines=True)
            c = self.peek()
            if c == "":
                return root
            if c == "[":
                if self.s.startswith("[[", self.i):
                    self.err("arrays de tablas ([[x]]) no soportados")
                self.i += 1
                ks = self.dotted()
                self.skip_ws()
                if self.peek() != "]":
                    self.err("se esperaba ]")
                self.i += 1
                self.end_of_line()
                cur = root
                for k in ks:
                    cur = cur.setdefault(k, {})
                    if not isinstance(cur, dict):
                        self.err("tabla redefinida: %s" % k)
            else:
                ks = self.dotted()
                self.skip_ws()
                if self.peek() != "=":
                    self.err("se esperaba =")
                self.i += 1
                v = self.value()
                self.end_of_line()
                _set(cur, ks, v)


def _set(d, ks, v):
    for k in ks[:-1]:
        d = d.setdefault(k, {})
    if ks[-1] in d:
        raise TomlError("clave duplicada: %s" % ks[-1])
    d[ks[-1]] = v
