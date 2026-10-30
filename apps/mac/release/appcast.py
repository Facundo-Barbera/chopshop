#!/usr/bin/env python3
import argparse
import base64
import hashlib
import json
import os
import re
import sys
import xml.etree.ElementTree as ET

NS = "http://www.andymatuschak.org/xml-namespaces/sparkle"
SP = "{%s}" % NS


_P = 2 ** 255 - 19
_Q = 2 ** 252 + 27742317777372353535851937790883648493
_D = -121665 * pow(121666, _P - 2, _P) % _P
_SQRT_M1 = pow(2, (_P - 1) // 4, _P)


def _inv(x):
    return pow(x, _P - 2, _P)


def _recover_x(y, sign):
    if y >= _P:
        return None
    x2 = (y * y - 1) * _inv(_D * y * y + 1)
    if x2 == 0:
        return None if sign else 0
    x = pow(x2, (_P + 3) // 8, _P)
    if (x * x - x2) % _P != 0:
        x = x * _SQRT_M1 % _P
    if (x * x - x2) % _P != 0:
        return None
    if (x & 1) != sign:
        x = _P - x
    return x


def _add(a, b):
    A, B = (a[1] - a[0]) * (b[1] - b[0]) % _P, (a[1] + a[0]) * (b[1] + b[0]) % _P
    C, D = 2 * a[3] * b[3] * _D % _P, 2 * a[2] * b[2] % _P
    E, F, G, H = B - A, D - C, D + C, B + A
    return (E * F % _P, G * H % _P, F * G % _P, E * H % _P)


def _mul(s, pt):
    q = (0, 1, 1, 0)
    while s > 0:
        if s & 1:
            q = _add(q, pt)
        pt = _add(pt, pt)
        s >>= 1
    return q


def _eq(a, b):
    return (a[0] * b[2] - b[0] * a[2]) % _P == 0 and (a[1] * b[2] - b[1] * a[2]) % _P == 0


_GY = 4 * _inv(5) % _P
_GX = _recover_x(_GY, 0)
_G = (_GX, _GY, 1, _GX * _GY % _P)


def _compress(pt):
    zinv = _inv(pt[2])
    x, y = pt[0] * zinv % _P, pt[1] * zinv % _P
    return int.to_bytes(y | ((x & 1) << 255), 32, "little")


def _decompress(s):
    if len(s) != 32:
        return None
    y = int.from_bytes(s, "little")
    sign = y >> 255
    y &= (1 << 255) - 1
    x = _recover_x(y, sign)
    return None if x is None else (x, y, 1, x * y % _P)


def ed25519_public_from_seed(seed):
    if len(seed) != 32:
        raise ValueError("la semilla debe tener 32 bytes")
    h = hashlib.sha512(seed).digest()
    a = int.from_bytes(h[:32], "little")
    a &= (1 << 254) - 8
    a |= 1 << 254
    return _compress(_mul(a, _G))


def ed25519_verify(public, msg, sig):
    if len(public) != 32 or len(sig) != 64:
        return False
    a_pt = _decompress(public)
    r_bytes = sig[:32]
    r_pt = _decompress(r_bytes)
    if a_pt is None or r_pt is None:
        return False
    s = int.from_bytes(sig[32:], "little")
    if s >= _Q:
        return False
    h = int.from_bytes(hashlib.sha512(r_bytes + public + msg).digest(), "little") % _Q
    return _eq(_mul(s, _G), _add(r_pt, _mul(h, a_pt)))


def public_from_sparkle_secret(secret_b64):
    raw = base64.b64decode(secret_b64.strip(), validate=True)
    if len(raw) == 32:
        return ed25519_public_from_seed(raw)
    if len(raw) == 96:
        return raw[64:]
    raise ValueError("la clave privada de Sparkle debe decodificar a 32 o 96 bytes")


def version_key(v):
    parts = []
    for p in re.split(r"[.]", v.strip()):
        m = re.match(r"^(\d+)(.*)$", p)
        parts.append((int(m.group(1)), m.group(2)) if m else (-1, p))
    while parts and parts[-1] == (0, ""):
        parts.pop()
    return parts


def load_items(path):
    root = ET.parse(path).getroot()
    channel = root.find("channel")
    items = []
    if channel is None:
        return items
    for it in channel.findall("item"):
        enc = it.find("enclosure")
        if enc is None:
            continue
        rec = {
            "build": it.findtext(SP + "version") or enc.get(SP + "version") or "",
            "short": it.findtext(SP + "shortVersionString") or enc.get(SP + "shortVersionString") or "",
            "min_system": it.findtext(SP + "minimumSystemVersion") or "",
            "channel": it.findtext(SP + "channel") or "",
            "url": enc.get("url") or "",
            "sig": enc.get(SP + "edSignature") or "",
            "length": enc.get("length") or "",
            "deltas": [],
        }
        deltas = it.find(SP + "deltas")
        if deltas is not None:
            for d in deltas.findall("enclosure"):
                rec["deltas"].append({
                    "url": d.get("url") or "",
                    "sig": d.get(SP + "edSignature") or "",
                    "from": d.get(SP + "deltaFrom") or "",
                    "length": d.get("length") or "",
                })
        items.append(rec)
    return items


def basename_of(url):
    return url.split("?", 1)[0].rstrip("/").rsplit("/", 1)[-1]


def sha256_file(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def cmd_check_new(a):
    zip_path = a.archive
    appcast = os.path.join(a.dir, "appcast.xml")
    items = load_items(appcast) if os.path.exists(appcast) else []
    status = 0
    same = [i for i in items if i["short"] == a.version]
    if same:
        remote_zip = os.path.join(a.dir, basename_of(same[0]["url"]))
        if os.path.exists(remote_zip) and sha256_file(remote_zip) == sha256_file(zip_path):
            print("la versión %s ya está publicada con un zip idéntico: reintento idempotente" % a.version)
            status = 3
        else:
            print("ERROR: la versión %s ya existe en el appcast con otro contenido; no se pisa un release publicado "
                  "(sube la versión, o haz rollback explícito antes)" % a.version, file=sys.stderr)
            return 1
    others = [i for i in items if i["short"] != a.version]
    if others:
        top = max((i["build"] for i in others), key=version_key)
        if version_key(a.build) <= version_key(top):
            print("ERROR: CFBundleVersion %s no es mayor que el máximo publicado (%s); Sparkle no lo ofrecería. "
                  "Si hay un release más nuevo en cola, relanza éste después" % (a.build, top), file=sys.stderr)
            return 1
    existing = os.path.join(a.dir, os.path.basename(zip_path))
    if os.path.exists(existing) and os.path.abspath(existing) != os.path.abspath(zip_path):
        if sha256_file(existing) != sha256_file(zip_path):
            print("ERROR: %s ya existe en el bucket con otro contenido" % os.path.basename(zip_path), file=sys.stderr)
            return 1
    return status


def _feed_is_signed(path):
    with open(path, "rb") as f:
        return b"sparkle-signatures" in f.read()


def cmd_verify(a):
    appcast = os.path.join(a.dir, "appcast.xml")
    errors = []
    items = load_items(appcast)
    base = a.base_url.rstrip("/") + "/"
    if not items:
        errors.append("el appcast no tiene items")
    new = [i for i in items if i["short"] == a.version and i["build"] == a.build] if a.version else []
    if a.version and len(new) != 1:
        errors.append("debe haber exactamente un item con versión %s y build %s (hay %d)" % (a.version, a.build, len(new)))
    if a.absent:
        if any(i["short"] == a.absent for i in items):
            errors.append("la versión %s sigue en el appcast" % a.absent)
    for i in items:
        label = i["short"] or i["build"]
        for enc in [{"url": i["url"], "sig": i["sig"]}] + i["deltas"]:
            if not enc["url"].startswith(base):
                errors.append("%s: url fuera de UPDATES_BASE_URL" % label)
            if not enc["sig"]:
                errors.append("%s: enclosure sin sparkle:edSignature" % label)
            name = basename_of(enc["url"])
            if not os.path.exists(os.path.join(a.dir, name)):
                errors.append("%s: el feed referencia %s pero no está en el directorio a publicar" % (label, name))
        if i["min_system"] and a.min_system and version_key(i["min_system"]) < version_key(a.min_system):
            errors.append("%s: minimumSystemVersion %s < %s" % (label, i["min_system"], a.min_system))
    if new:
        n = new[0]
        if not n["min_system"]:
            errors.append("el item nuevo no trae sparkle:minimumSystemVersion")
        elif a.min_system and version_key(n["min_system"]) != version_key(a.min_system):
            errors.append("el item nuevo tiene minimumSystemVersion %s y se esperaba %s" % (n["min_system"], a.min_system))
        if (n["channel"] or "") != (a.channel or ""):
            errors.append("canal del item nuevo '%s' != esperado '%s'" % (n["channel"], a.channel or ""))
        if a.public:
            pub = base64.b64decode(a.public)
            zpath = os.path.join(a.dir, basename_of(n["url"]))
            if os.path.exists(zpath) and n["sig"]:
                with open(zpath, "rb") as f:
                    data = f.read()
                if not ed25519_verify(pub, data, base64.b64decode(n["sig"])):
                    errors.append("la firma EdDSA del zip nuevo NO coincide con la clave pública (SUPublicEDKey)")
                if str(len(data)) != n["length"]:
                    errors.append("length del enclosure != tamaño real del zip")
            for d in n["deltas"]:
                dpath = os.path.join(a.dir, basename_of(d["url"]))
                if os.path.exists(dpath) and d["sig"]:
                    with open(dpath, "rb") as f:
                        ok = ed25519_verify(pub, f.read(), base64.b64decode(d["sig"]))
                    if not ok:
                        errors.append("firma de un delta no coincide con la clave pública")
    if a.require_signed_feed and not _feed_is_signed(appcast):
        errors.append("SURequireSignedFeed está activo en la app pero el appcast no está firmado")
    for e in errors:
        print("ERROR: " + e, file=sys.stderr)
    if not errors:
        print("appcast OK: %d item(s)%s" % (len(items), ", nuevo %s (build %s)" % (a.version, a.build) if a.version else ""))
    return 1 if errors else 0


def cmd_find(a):
    items = load_items(a.appcast)
    hit = [i for i in items if i["short"] == a.version]
    if not hit:
        print("la versión %s no está en el appcast" % a.version, file=sys.stderr)
        return 1
    it = hit[0]
    files = [basename_of(it["url"])]
    files += [basename_of(d["url"]) for d in it["deltas"]]
    for other in items:
        if other is not it:
            files += [basename_of(d["url"]) for d in other["deltas"] if d["from"] == it["build"]]
    print(json.dumps({"build": it["build"], "short": it["short"], "files": sorted(set(files)), "remaining": len(items) - 1}))
    return 0


def cmd_remove_item(a):
    ET.register_namespace("sparkle", NS)
    ET.register_namespace("dc", "http://purl.org/dc/elements/1.1/")
    tree = ET.parse(a.appcast)
    channel = tree.getroot().find("channel")
    removed = 0
    for it in list(channel.findall("item")):
        short = it.findtext(SP + "shortVersionString") or (it.find("enclosure").get(SP + "shortVersionString") if it.find("enclosure") is not None else "")
        if short == a.version:
            channel.remove(it)
            removed += 1
    tree.write(a.appcast, encoding="utf-8", xml_declaration=True)
    print("items retirados: %d" % removed)
    return 0 if removed else 1


def cmd_get_sig(a):
    for i in load_items(a.appcast):
        if i["short"] == a.version and i["sig"]:
            print(i["sig"])
            return 0
    return 1


def cmd_prune(a):
    ET.register_namespace("sparkle", NS)
    ET.register_namespace("dc", "http://purl.org/dc/elements/1.1/")
    tree = ET.parse(a.appcast)
    channel = tree.getroot().find("channel")
    removed_items = removed_deltas = 0
    for it in list(channel.findall("item")):
        enc = it.find("enclosure")
        short = it.findtext(SP + "shortVersionString") or (enc.get(SP + "shortVersionString") if enc is not None else "")
        if short == a.version:
            channel.remove(it)
            removed_items += 1
            continue
        deltas = it.find(SP + "deltas")
        if deltas is None:
            continue
        for d in list(deltas.findall("enclosure")):
            if not os.path.exists(os.path.join(a.dir, basename_of(d.get("url") or ""))):
                deltas.remove(d)
                removed_deltas += 1
        if not deltas.findall("enclosure"):
            it.remove(deltas)
    tree.write(a.appcast, encoding="utf-8", xml_declaration=True)
    print("items retirados: %d, deltas huérfanos retirados: %d" % (removed_items, removed_deltas))
    return 0


def cmd_list_files(a):
    seen = []
    for i in load_items(a.appcast):
        for url in [i["url"]] + [d["url"] for d in i["deltas"]]:
            n = basename_of(url)
            if n and n not in seen:
                seen.append(n)
    print("\n".join(seen))
    return 0


def cmd_max_build(a):
    items = load_items(a.appcast)
    print(max((i["build"] for i in items), key=version_key) if items else "")
    return 0


def _read_stdin_secret():
    data = sys.stdin.read().strip()
    if not data:
        raise SystemExit("ERROR: no llegó la clave privada por stdin")
    return data


def cmd_derive_public(_a):
    print(base64.b64encode(public_from_sparkle_secret(_read_stdin_secret())).decode())
    return 0


def cmd_check_key(a):
    derived = public_from_sparkle_secret(_read_stdin_secret())
    if derived != base64.b64decode(a.public):
        print("ERROR: la clave privada (SPARKLE_ED_PRIVATE_KEY) no corresponde a SPARKLE_ED_PUBLIC_KEY", file=sys.stderr)
        return 1
    print("clave privada y pública de Sparkle coinciden")
    return 0


def cmd_verify_sig(a):
    with open(a.file, "rb") as f:
        ok = ed25519_verify(base64.b64decode(a.public), f.read(), base64.b64decode(a.sig))
    if not ok:
        print("ERROR: la firma no coincide con la clave pública", file=sys.stderr)
    return 0 if ok else 1


def main(argv=None):
    ap = argparse.ArgumentParser(description="Utilidades de appcast/Sparkle para el pipeline de release.")
    sub = ap.add_subparsers(dest="cmd", required=True)
    sub.add_parser("derive-public").set_defaults(fn=cmd_derive_public)
    p = sub.add_parser("check-key")
    p.add_argument("--public", required=True)
    p.set_defaults(fn=cmd_check_key)
    p = sub.add_parser("verify-sig")
    p.add_argument("--public", required=True)
    p.add_argument("--file", required=True)
    p.add_argument("--sig", required=True)
    p.set_defaults(fn=cmd_verify_sig)
    p = sub.add_parser("max-build")
    p.add_argument("--appcast", required=True)
    p.set_defaults(fn=cmd_max_build)
    p = sub.add_parser("get-sig")
    p.add_argument("--appcast", required=True)
    p.add_argument("--version", required=True)
    p.set_defaults(fn=cmd_get_sig)
    p = sub.add_parser("list-files")
    p.add_argument("--appcast", required=True)
    p.set_defaults(fn=cmd_list_files)
    p = sub.add_parser("check-new")
    p.add_argument("--dir", required=True)
    p.add_argument("--archive", required=True)
    p.add_argument("--version", required=True)
    p.add_argument("--build", required=True)
    p.set_defaults(fn=cmd_check_new)
    p = sub.add_parser("verify")
    p.add_argument("--dir", required=True)
    p.add_argument("--base-url", required=True)
    p.add_argument("--version", default="")
    p.add_argument("--build", default="")
    p.add_argument("--absent", default="", help="versión que NO debe estar en el feed (rollback)")
    p.add_argument("--min-system", default="")
    p.add_argument("--channel", default="")
    p.add_argument("--public", default="")
    p.add_argument("--require-signed-feed", action="store_true")
    p.set_defaults(fn=cmd_verify)
    p = sub.add_parser("find")
    p.add_argument("--appcast", required=True)
    p.add_argument("--version", required=True)
    p.set_defaults(fn=cmd_find)
    p = sub.add_parser("prune")
    p.add_argument("--appcast", required=True)
    p.add_argument("--dir", required=True)
    p.add_argument("--version", required=True)
    p.set_defaults(fn=cmd_prune)
    p = sub.add_parser("remove-item")
    p.add_argument("--appcast", required=True)
    p.add_argument("--version", required=True)
    p.set_defaults(fn=cmd_remove_item)
    args = ap.parse_args(argv)
    return args.fn(args)


if __name__ == "__main__":
    sys.exit(main())
