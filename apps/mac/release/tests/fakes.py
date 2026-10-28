"""Dobles de prueba del pipeline de release: ejecutables falsos (security, codesign, xcrun, aws, curl,
generate_appcast...) que registran sus llamadas en $SHIM_LOG. Así los scripts reales se ejercitan en Linux,
sin credenciales ni servicios, y se puede comprobar el ORDEN de las operaciones y que no se filtren secretos.
Todos los datos son ficticios."""
import base64
import hashlib
import importlib.util
import os
import stat
import subprocess
import sys
import textwrap

HERE = os.path.dirname(os.path.abspath(__file__))
RELEASE = os.path.abspath(os.path.join(HERE, ".."))

_spec = importlib.util.spec_from_file_location("appcast_mod", os.path.join(RELEASE, "appcast.py"))
appcast = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(appcast)

SEED = bytes(range(32))  # semilla de juguete; NO es una clave real
SECRET_B64 = base64.b64encode(SEED).decode()
PUBLIC_B64 = base64.b64encode(appcast.ed25519_public_from_seed(SEED)).decode()


def ed25519_sign(seed, msg):
    """Firma Ed25519 (RFC 8032) solo para las pruebas; el pipeline real firma con generate_appcast."""
    p, q = appcast._P, appcast._Q
    h = hashlib.sha512(seed).digest()
    a = int.from_bytes(h[:32], "little")
    a &= (1 << 254) - 8
    a |= 1 << 254
    pub = appcast._compress(appcast._mul(a, appcast._G))
    r = int.from_bytes(hashlib.sha512(h[32:] + msg).digest(), "little") % q
    r_enc = appcast._compress(appcast._mul(r, appcast._G))
    k = int.from_bytes(hashlib.sha512(r_enc + pub + msg).digest(), "little") % q
    s = (r + k * a) % q
    return r_enc + int.to_bytes(s, 32, "little")


PRELUDE = '''#!/usr/bin/env python3
import os, sys
LOG = os.environ.get("SHIM_LOG", os.devnull)
def log(*a):
    with open(LOG, "a") as f:
        f.write(" ".join(str(x) for x in a) + "\\n")
'''

SHIMS = {}

SHIMS["security"] = PRELUDE + '''
args = sys.argv[1:]
log("security", *args)
cmd = args[0]
if cmd == "list-keychains" and "-s" not in args:
    print('    "/tmp/fake/login.keychain-db"')
elif cmd == "find-identity":
    n = int(os.environ.get("FAKE_IDENTITIES", "1"))
    for i in range(n):
        print('  %d) %040X "Developer ID Application: Nombre Demo (ABCDE12345)"' % (i + 1, i + 1))
    print("     %d valid identities found" % n)
elif cmd == "import":
    if not os.path.exists(args[1]):
        sys.exit(1)
    log("import-p12-existed-at-import", "yes")
'''

SHIMS["codesign"] = PRELUDE + '''
args = sys.argv[1:]
log("codesign", *args)
if "-d" in args:
    sys.stderr.write("CodeDirectory v=20500 size=1 flags=0x10000(runtime) hashes=1\\n")
    if os.environ.get("FAKE_TIMESTAMP", "1") == "1":
        sys.stderr.write("Timestamp=Oct 28, 2026 at 10:00:00\\n")
    sys.stderr.write("TeamIdentifier=%s\\n" % os.environ.get("FAKE_TEAM", "ABCDE12345"))
'''

SHIMS["spctl"] = PRELUDE + '''
log("spctl", *sys.argv[1:])
print("origin=Developer ID Application: Nombre Demo (ABCDE12345)")
'''

SHIMS["xcrun"] = PRELUDE + '''
args = sys.argv[1:]
log("xcrun", *args)
if args[:2] == ["notarytool", "submit"]:
    key = args[args.index("--key") + 1]
    log("key-file-existed", "yes" if os.path.exists(key) else "no")
    status = os.environ.get("FAKE_NOTARY_STATUS", "Accepted")
    print('{"id": "sub-0001", "status": "%s", "message": "demo"}' % status)
    sys.exit(0 if status == "Accepted" else 1)
elif args[:2] == ["notarytool", "log"]:
    print('{"status": "Invalid", "issues": [{"message": "El binario no esta firmado"}]}')
'''

SHIMS["ditto"] = PRELUDE + '''
args = sys.argv[1:]
log("ditto", *args)
if "-x" in args:
    dest = args[-1]
    os.makedirs(os.path.join(dest, "Chopshop.app", "Contents"), exist_ok=True)
elif "-c" in args:
    open(args[-1], "wb").write(b"zip-falso")
else:
    import shutil
    shutil.copytree(args[0], args[1], symlinks=True)
'''

SHIMS["shasum"] = PRELUDE + '''
import hashlib
args = sys.argv[1:]
if "-c" in args:
    line = open(args[-1]).read().split()
    ok = hashlib.sha256(open(line[1], "rb").read()).hexdigest() == line[0]
    print("%s: %s" % (line[1], "OK" if ok else "FAILED"))
    sys.exit(0 if ok else 1)
for f in args[2:]:
    print("%s  %s" % (hashlib.sha256(open(f, "rb").read()).hexdigest(), f))
'''

SHIMS["PlistBuddy"] = PRELUDE + '''
import json, shlex
args = sys.argv[1:]
cmd, path = args[1], args[2]
log("PlistBuddy", cmd)
data = json.load(open(path)) if os.path.exists(path) else {}
op, _, rest = cmd.partition(" ")
if op == "Print":
    key = rest.lstrip(":")
    if key not in data:
        sys.exit(1)
    v = data[key]
    print(("true" if v else "false") if isinstance(v, bool) else v)
    sys.exit(0)
if op == "Delete":
    key = rest.lstrip(":")
    if key not in data:
        sys.exit(1)
    del data[key]
elif op == "Add":
    parts = shlex.split(rest)
    key, typ, val = parts[0].lstrip(":"), parts[1], parts[2]
    data[key] = (val == "true") if typ == "bool" else int(val) if typ == "integer" else val
json.dump(data, open(path, "w"))
'''

SHIMS["otool"] = PRELUDE + '''
args = sys.argv[1:]
if args[0] == "-L":
    print(args[1] + ":")
    print("\\t@rpath/Sparkle.framework/Versions/B/Sparkle (compatibility version 1.6.0, current version 2.10.1)")
else:
    print("Load command 9\\n      cmd LC_BUILD_VERSION\\n  cmdsize 32\\n platform 1\\n    minos %s\\n      sdk 26.0\\n   ntools 1" % os.environ.get("FAKE_MINOS", "13.0"))
    if os.environ.get("FAKE_RPATH") == "1":
        print("Load command 20\\n          cmd LC_RPATH\\n         path @executable_path/../Frameworks (offset 12)")
'''

SHIMS["install_name_tool"] = PRELUDE + '''
log("install_name_tool", *sys.argv[1:])
'''

SHIMS["aws"] = PRELUDE + '''
import shutil
store = os.environ["FAKE_S3_DIR"]
args = sys.argv[1:]
if args[0] == "--endpoint-url":
    args = args[2:]
def key_of(uri):
    rest = uri[len("s3://"):]
    return rest.split("/", 1)[1] if "/" in rest else ""
def opt(name):
    return args[args.index(name) + 1] if name in args else ""
if args[0] == "s3api" and args[1] == "head-object":
    if os.environ.get("FAKE_AWS_AUTH_FAIL"):
        sys.stderr.write("An error occurred (403) when calling the HeadObject operation: Forbidden\\n")
        sys.exit(254)
    p = os.path.join(store, opt("--key"))
    if os.path.isfile(p):
        print(os.path.getsize(p))
    else:
        sys.stderr.write("An error occurred (404) when calling the HeadObject operation: Not Found\\n")
        sys.exit(254)
elif args[0] == "s3" and args[1] == "cp":
    src, dst = args[2], args[3]
    if src.startswith("s3://"):
        shutil.copy(os.path.join(store, key_of(src)), dst)
        log("aws get", key_of(src))
    else:
        out = os.path.join(store, key_of(dst))
        os.makedirs(os.path.dirname(out), exist_ok=True)
        shutil.copy(src, out)
        log("aws put", key_of(dst), "cache=" + opt("--cache-control"), "type=" + opt("--content-type"))
elif args[0] == "s3" and args[1] == "mv":
    a, b = os.path.join(store, key_of(args[2])), os.path.join(store, key_of(args[3]))
    os.makedirs(os.path.dirname(b), exist_ok=True)
    shutil.move(a, b)
    log("aws mv", key_of(args[2]), "->", key_of(args[3]))
else:
    log("aws", *args)
'''

SHIMS["curl"] = PRELUDE + '''
import shutil
public = os.environ["FAKE_S3_DIR"]
args = sys.argv[1:]
if "-K" in args:
    cfg = sys.stdin.read()
    log("curl-config-via-stdin", "len=%d" % len(cfg))
url = [a for a in args if a.startswith("https://")][-1]
log("curl", *[a for a in args if not a.startswith("header")])
if "api.cloudflare.com" in url:
    log("cloudflare-purge", url)
    sys.exit(0)
path = url.split("://", 1)[1].split("/", 1)[1].split("?", 1)[0]
p = os.path.join(public, path)
if not os.path.isfile(p):
    sys.exit(22)
if "--output" in args and args[args.index("--output") + 1] != "/dev/null":
    shutil.copy(p, args[args.index("--output") + 1])
'''

SHIMS["sign_update"] = PRELUDE + '''
sys.path.insert(0, os.environ["RELEASE_DIR"])
import importlib.util
spec = importlib.util.spec_from_file_location("appcast_mod", os.path.join(os.environ["RELEASE_DIR"], "appcast.py"))
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
import base64
args = sys.argv[1:]
log("sign_update", *args)
secret = sys.stdin.readline().strip()
pub = m.public_from_sparkle_secret(secret)
if "--verify" in args:
    f, sig = args[-2], args[-1]
    ok = m.ed25519_verify(pub, open(f, "rb").read(), base64.b64decode(sig))
    sys.exit(0 if ok else 1)
if args[-1].endswith(".xml"):
    with open(args[-1], "a") as fh:
        fh.write("<!-- sparkle-signatures:\\nedSignature: re-firmado\\n-->\\n")
'''

SHIMS["generate_appcast"] = PRELUDE + '''
import base64, importlib.util, hashlib
spec = importlib.util.spec_from_file_location("appcast_mod", os.path.join(os.environ["RELEASE_DIR"], "appcast.py"))
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
spec2 = importlib.util.spec_from_file_location("fakes_mod", os.path.join(os.environ["RELEASE_DIR"], "tests", "fakes.py"))
fk = importlib.util.module_from_spec(spec2); spec2.loader.exec_module(fk)
args = sys.argv[1:]
log("generate_appcast", *args)
secret = sys.stdin.readline().strip()
assert secret not in " ".join(args), "la clave privada no puede ir en argv"
seed = base64.b64decode(secret)
d = args[-1]
def opt(name, default=""):
    return args[args.index(name) + 1] if name in args else default
prefix = opt("--download-url-prefix")
new_build = opt("--versions")
channel = opt("--channel")
phased = opt("--phased-rollout-interval")
min_sys = os.environ.get("FAKE_MIN_SYSTEM", "13.0")
feed = os.path.join(d, "appcast.xml")
existing = m.load_items(feed) if os.path.exists(feed) else []
items = []
for it in existing:
    if os.path.exists(os.path.join(d, m.basename_of(it["url"]))) or os.environ.get("FAKE_KEEP_STALE_ITEM"):
        items.append(it)
have = {i["short"] for i in items}
for name in sorted(os.listdir(d)):
    if name.startswith("Chopshop-") and name.endswith(".zip"):
        short = name[len("Chopshop-"):-len(".zip")]
        if short not in have and new_build:
            items.append({"build": new_build, "short": short, "channel": channel, "url": prefix + name, "min_system": min_sys, "phased": phased})
def xml_item(i):
    name = m.basename_of(i["url"])
    if not os.path.exists(os.path.join(d, name)):
        return ("<item><title>%s</title><sparkle:version>%s</sparkle:version><sparkle:shortVersionString>%s</sparkle:shortVersionString>"
                '<sparkle:minimumSystemVersion>13.0</sparkle:minimumSystemVersion><enclosure url="%s" length="1" sparkle:edSignature="x"/></item>'
                % (i["short"], i["build"], i["short"], i["url"]))
    data = open(os.path.join(d, name), "rb").read()
    sig = base64.b64encode(fk.ed25519_sign(seed, data)).decode()
    extra = ("<sparkle:channel>%s</sparkle:channel>" % i["channel"]) if i.get("channel") else ""
    extra += ("<sparkle:phasedRolloutInterval>%s</sparkle:phasedRolloutInterval>" % i["phased"]) if i.get("phased") else ""
    return ("<item><title>%s</title><sparkle:version>%s</sparkle:version><sparkle:shortVersionString>%s</sparkle:shortVersionString>"
            "<sparkle:minimumSystemVersion>%s</sparkle:minimumSystemVersion>%s"
            '<enclosure url="%s" length="%d" type="application/octet-stream" sparkle:edSignature="%s"/></item>'
            % (i["short"], i["build"], i["short"], i["min_system"] or min_sys, extra, i["url"], len(data), sig))
body = "".join(xml_item(i) for i in sorted(items, key=lambda i: m.version_key(i["build"]), reverse=True))
with open(feed, "w") as f:
    f.write('<?xml version="1.0" standalone="yes"?>\\n<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" version="2.0">'
            "<channel><title>Chopshop</title>%s</channel></rss>\\n<!-- sparkle-signatures:\\nedSignature: demo\\n-->\\n" % body)
'''


def install_shims(bindir):
    os.makedirs(bindir, exist_ok=True)
    for name, src in SHIMS.items():
        path = os.path.join(bindir, name)
        with open(path, "w") as f:
            f.write(src)
        os.chmod(path, os.stat(path).st_mode | stat.S_IEXEC | stat.S_IXGRP | stat.S_IXOTH)
    return bindir


def run_script(script, args=(), env=None, cwd=None, shims=None, stdin=None):
    """Ejecuta un script de release con los shims delante en PATH. Devuelve CompletedProcess (texto)."""
    full = dict(os.environ)
    for k in list(full):
        if k.startswith(("SPARKLE_", "R2_", "MACOS_", "APPLE_", "CLOUDFLARE_", "UPDATES_", "GITHUB_")):
            del full[k]
    if shims:
        full["PATH"] = shims + os.pathsep + full["PATH"]
    full.update(env or {})
    return subprocess.run(["bash", os.path.join(RELEASE, script)] + list(args), env=full, cwd=cwd, input=stdin,
                          capture_output=True, text=True, timeout=120)
