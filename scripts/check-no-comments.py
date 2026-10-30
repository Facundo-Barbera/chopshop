#!/usr/bin/env python3
import ast
import io
import re
import subprocess
import sys
import tokenize

SHELL_DIRECTIVE = re.compile(r"#\s*shellcheck\s")
HEREDOC = re.compile(r"<<(-?)\s*(['\"]?)([A-Za-z_][A-Za-z0-9_]*)\2")


def python_comments(path, src):
    found = []
    for tok in tokenize.generate_tokens(io.StringIO(src).readline):
        if tok.type == tokenize.COMMENT and not (tok.start[0] == 1 and tok.string.startswith("#!")):
            found.append(tok.start[0])
    for node in ast.walk(ast.parse(src, path)):
        if isinstance(node, (ast.Module, ast.ClassDef, ast.FunctionDef, ast.AsyncFunctionDef)) and ast.get_docstring(node) is not None:
            found.append(node.body[0].lineno)
    return found


def shell_comments(path, src):
    found = []
    state = None
    heredocs = []
    for n, line in enumerate(src.split("\n"), 1):
        if heredocs:
            dash, delim = heredocs[0]
            if (line.lstrip("\t") if dash else line) == delim:
                heredocs.pop(0)
            continue
        if n == 1 and line.startswith("#!"):
            continue
        j = 0
        prev = "\n"
        while j < len(line):
            c = line[j]
            if state == "'":
                if c == "'":
                    state = None
            elif state == '"':
                if c == "\\":
                    j += 1
                elif c == '"':
                    state = None
            elif c == "\\":
                j += 1
            elif c in "'\"":
                state = c
            elif line.startswith("<<", j) and not line.startswith("<<<", j) and HEREDOC.match(line, j):
                m = HEREDOC.match(line, j)
                heredocs.append((m.group(1) == "-", m.group(3)))
                j = m.end()
                prev = "x"
                continue
            elif c == "#" and prev in " \t\n;&|()":
                if not SHELL_DIRECTIVE.match(line[j:]):
                    found.append(n)
                break
            prev = line[j] if j < len(line) else prev
            j += 1
    return found


def yaml_comments(path, src):
    found = []
    for n, line in enumerate(src.split("\n"), 1):
        quote = None
        for j, c in enumerate(line):
            if quote:
                if c == quote:
                    quote = None
            elif c in "'\"" and (j == 0 or line[j - 1] in " :[{,-"):
                quote = c
            elif c == "#" and (j == 0 or line[j - 1] in " \t") and not line[:j].rstrip().endswith("${{"):
                found.append(n)
                break
    return found


def block_comments(path, src):
    return [src.count("\n", 0, m.start()) + 1 for m in re.finditer(r"/\*|(?<![:\"'])//", src)]


def checker(path):
    if path.endswith(".py"):
        return python_comments
    if path.endswith((".sh", ".version")) or path == "apps/agent/bin/chopshop":
        return shell_comments
    if path.startswith(".github/workflows/") and path.endswith((".yml", ".yaml")):
        return yaml_comments
    if path.endswith((".css", ".d.ts")):
        return block_comments
    return None


def main():
    files = subprocess.run(["git", "ls-files"], capture_output=True, text=True, check=True).stdout.split()
    bad = 0
    for path in files:
        check = checker(path)
        if check is None:
            continue
        with open(path, encoding="utf-8") as f:
            src = f.read()
        for line in check(path, src):
            print(f"{path}:{line}: comentario prohibido")
            bad += 1
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
