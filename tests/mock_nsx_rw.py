"""A writable stand-in for an NSX Local/Global Manager policy API, with fault injection.

  python3 tests/mock_nsx_rw.py <state.json> <request-log> <port> <cert.pem> <key.pem> <control.json>

tests/mock_nsx.py refuses every write, to prove a plan or an import changes
nothing. This one accepts them, so the real provider can create, update and
delete, and behaves as NSX does where that matters to this repository: a group
or service that a rule still uses cannot be deleted (error 500030), lists are
paged with a cursor, and a policy is returned with its rules.

Objects live in memory keyed by policy path and are persisted to <state.json> after every
write, so a test can inspect what "NSX" holds and edit it to simulate UI changes (the file
is re-read when its mtime changes and differs from what we last wrote).

control.json (re-read on every request) injects faults:
  {"write_fail_rate": 0.2, "read_fail_rate": 0.0, "fail_codes": [503, 429],
   "latency_ms": 0, "die_after_writes": -1, "seed": 1}
"""
import json, os, random, re, ssl, sys, threading, time, urllib.parse, itertools
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

state_file, log_file, port, cert, key, control_file = sys.argv[1], sys.argv[2], int(sys.argv[3]), sys.argv[4], sys.argv[5], sys.argv[6]
log = open(log_file, "a")
lock = threading.RLock()
objs = {}            # canonical path (e.g. /infra/domains/default/groups/x) -> body
loaded_mtime = None
written_mtime = None
writes = 0
rule_ids = itertools.count(1000)
rng = random.Random(1)

PREFIXES = ("/policy/api/v1", "/global-manager/api/v1")
PREDEFINED = ["HTTPS", "HTTP", "SSH", "DNS-UDP", "DNS", "NTP", "ICMP-ALL", "LDAP", "MS-SQL-S", "RDP"]


def seed_predefined():
    for root in ("/infra", "/global-infra"):
        for name in PREDEFINED:
            p = f"{root}/services/{name}"
            objs.setdefault(p, {"id": name, "display_name": name, "path": p, "relative_path": name,
                                "parent_path": root, "resource_type": "Service", "_revision": 0,
                                "_system_owned": True,
                                "service_entries": [{"resource_type": "L4PortSetServiceEntry",
                                                     "display_name": name, "l4_protocol": "TCP",
                                                     "destination_ports": ["443"]}]})


def load():
    global loaded_mtime
    try:
        m = os.stat(state_file).st_mtime_ns
    except FileNotFoundError:
        seed_predefined(); return
    if m in (loaded_mtime, written_mtime):
        return
    with open(state_file) as f:
        data = json.load(f)
    objs.clear(); objs.update(data)
    seed_predefined()
    loaded_mtime = m


def save():
    global written_mtime
    tmp = state_file + ".tmp"
    with open(tmp, "w") as f:
        json.dump({k: v for k, v in objs.items() if not v.get("_system_owned")}, f, indent=1, sort_keys=True)
    os.replace(tmp, state_file)
    written_mtime = os.stat(state_file).st_mtime_ns


def control():
    try:
        with open(control_file) as f:
            return json.load(f)
    except Exception:
        return {}


RTYPE = {"groups": "Group", "services": "Service", "security-policies": "SecurityPolicy", "rules": "Rule",
         "segments": "Segment", "tier-1s": "Tier1", "tier-0s": "Tier0", "domains": "Domain",
         "service-entries": "ServiceEntry"}


def canonical(raw):
    path = urllib.parse.unquote(raw.split("?")[0])
    for pre in PREFIXES:
        if path.startswith(pre):
            return pre, path[len(pre):]
    return None, path


def decorate(path, body, old):
    parts = path.rstrip("/").split("/")
    body = dict(old or {}, **body)
    body["id"] = parts[-1]
    body["path"] = path
    body["relative_path"] = parts[-1]
    body["parent_path"] = "/".join(parts[:-2]) or "/"
    body["resource_type"] = body.get("resource_type") or RTYPE.get(parts[-2], "Unknown")
    body["_revision"] = (old or {}).get("_revision", -1) + 1
    body.setdefault("display_name", parts[-1])
    body.setdefault("marked_for_delete", False)
    body["_last_modified_user"] = "terraform"
    body["_last_modified_time"] = int(time.time() * 1000)
    if body["resource_type"] == "Rule" and "rule_id" not in body:
        body["rule_id"] = next(rule_ids)
    if body["resource_type"] == "Rule":
        body.setdefault("ip_protocol", "IPV4_IPV6")
    if body["resource_type"] == "Service":
        for i, e in enumerate(body.get("service_entries") or []):
            e.setdefault("id", e.get("display_name") or f"entry-{i}")
            e.setdefault("path", f"{path}/service-entries/{e['id']}")
            e.setdefault("parent_path", path)
            e.setdefault("_revision", 0)
    return body


def children_of(path):
    return [o for k, o in objs.items() if k.startswith(path + "/") and "/" not in k[len(path) + 1:]]


COLL = {"Domain": "domains", "SecurityPolicy": "security-policies", "Rule": "rules", "Group": "groups",
        "Service": "services", "GatewayPolicy": "gateway-policies", "Segment": "segments", "Tier1": "tier-1s",
        "Tier0": "tier-0s"}


def hapi(parent, node):
    """Apply a hierarchical (H-API) PATCH body under parent path."""
    for child in node.get("children") or []:
        rt = child.get("resource_type", "")
        if rt == "ChildResourceReference":
            p = f"{parent}/{COLL[child['target_type']]}/{child['id']}"
            hapi(p, child)
            continue
        kind = rt[len("Child"):]
        obj = dict(child[kind])
        p = f"{parent}/{COLL[kind]}/{obj['id']}"
        if child.get("marked_for_delete") or obj.get("marked_for_delete"):
            for k in [k for k in objs if k == p or k.startswith(p + "/")]:
                del objs[k]
            continue
        sub = obj.pop("children", None)
        obj.pop("rules", None)
        objs[p] = decorate(p, obj, objs.get(p))
        if sub:
            hapi(p, {"children": sub})


class H(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def send(self, code, body=None, headers=()):
        data = b"" if body is None else json.dumps(body).encode()
        self.send_response(code)
        for k, v in headers:
            self.send_header(k, v)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)
        log.write(f"{self.command} {self.path} -> {code}\n"); log.flush()

    def body(self):
        n = int(self.headers.get("Content-Length") or 0)
        raw = self.rfile.read(n) if n else b""
        try:
            return json.loads(raw) if raw else {}
        except ValueError:
            return {}

    def fault(self, is_write):
        c = control()
        if c.get("latency_ms"):
            time.sleep(c["latency_ms"] / 1000)
        rate = c.get("write_fail_rate" if is_write else "read_fail_rate", 0)
        if rate and rng.random() < rate:
            code = rng.choice(c.get("fail_codes", [503]))
            msg = {"httpStatus": "SERVICE_UNAVAILABLE", "error_code": 503 if code == 503 else 102,
                   "module_name": "common-services", "error_message": f"mock: injected {code}"}
            if code == 429:
                msg = {"httpStatus": "TOO_MANY_REQUESTS", "error_code": 102, "module_name": "common-services",
                       "error_message": "Client 'admin' exceeded request rate of 100 per second."}
            self.send(code, msg)
            return True
        if is_write and c.get("die_after_writes", -1) >= 0 and writes >= c["die_after_writes"]:
            log.write(f"DIE at write {writes}: {self.command} {self.path}\n"); log.flush()
            self.connection.close()
            os._exit(3)
        return False

    def do_GET(self):
        with lock:
            load()
            if self.path.startswith("/api/v1/node"):
                return self.send(200, {"node_version": "4.1.2.0.0", "product_version": "4.1.2.0.0"})
            if self.path.startswith("/global-manager/api/v1/global-infra/global-managers") or self.path.startswith("/api/v1/global-infra"):
                return self.send(200, {"results": [], "result_count": 0})
            if self.fault(False):
                return
            pre, path = canonical(self.path)
            if "/search" in path:
                q = urllib.parse.unquote(self.path.partition("query=")[2].split("&")[0])
                m = re.search(r"display_name:\(?\"?((?:\\.|[^\s\")&\\])+)", q)
                want = re.sub(r"\\(.)", r"\1", m.group(1)).rstrip("*") if m else None
                rt = re.search(r"resource_type:(\w+)", q)
                found = [o for o in objs.values()
                         if (not rt or o.get("resource_type") == rt.group(1))
                         and (want is None or o.get("display_name", "").startswith(want))
                         and o.get("path", "").startswith("/global-infra" if pre == "/global-manager/api/v1" else "/infra")]
                return self.send(200, {"results": found, "result_count": len(found)})
            if path in objs:
                body = objs[path]
                if body.get("resource_type") == "SecurityPolicy":
                    # NSX returns a policy with its rules, as the importer reads it.
                    body = dict(body, rules=sorted(children_of(path + "/rules"), key=lambda r: r["path"]))
                return self.send(200, body)
            kids = children_of(path)
            if kids or path.endswith(("/groups", "/services", "/security-policies", "/rules", "/segments", "/tier-1s", "/tier-0s")):
                # Pagination like NSX: page_size defaults to 1000 and a cursor is returned.
                qs = urllib.parse.parse_qs(self.path.partition("?")[2])
                size = int((qs.get("page_size") or ["1000"])[0])
                start = int((qs.get("cursor") or ["0"])[0] or 0)
                kids.sort(key=lambda o: o["path"])
                page = kids[start:start + size]
                out = {"results": page, "result_count": len(kids)}
                if start + size < len(kids):
                    out["cursor"] = str(start + size)
                return self.send(200, out)
            return self.send(404, {"httpStatus": "NOT_FOUND", "error_code": 500090,
                                   "module_name": "policy", "error_message": f"The path={path} is invalid."})

    def do_PATCH(self):
        self.write(merge=True)

    def do_PUT(self):
        self.write(merge=False)

    def do_POST(self):
        if self.path.startswith("/api/session/create"):
            self.send_response(200)
            self.send_header("Set-Cookie", "JSESSIONID=x; Path=/")
            self.send_header("X-XSRF-TOKEN", "t")
            self.send_header("Content-Length", "0")
            self.end_headers()
            return
        self.write(merge=True)

    def write(self, merge):
        global writes
        body = self.body()
        with lock:
            load()
            if self.fault(True):
                return
            pre, path = canonical(self.path)
            if pre is None:
                return self.send(404, {"error_message": "unknown api"})
            writes += 1
            old = objs.get(path)
            if not merge and old and "_revision" in body and body["_revision"] != old.get("_revision"):
                return self.send(412, {"error_code": 604, "error_message": "Object revision mismatch"})
            if path in ("/infra", "/global-infra"):
                try:
                    hapi(path, body)
                except Exception as e:
                    return self.send(400, {"error_message": f"mock: H-API {e}"})
                save()
                return self.send(200)
            # Embedded rules on a security policy write are stored as their own objects (like NSX).
            rules = body.pop("rules", None)
            objs[path] = decorate(path, body, old if merge else (old and {"_revision": old["_revision"]}))
            if rules is not None:
                for r in rules:
                    rp = f"{path}/rules/{r['id']}"
                    objs[rp] = decorate(rp, r, objs.get(rp))
            save()
            if self.command == "PUT":
                return self.send(200, objs[path])
            return self.send(200)

    def do_DELETE(self):
        global writes
        with lock:
            load()
            if self.fault(True):
                return
            pre, path = canonical(self.path)
            writes += 1
            if path not in objs:
                return self.send(200)
            # NSX refuses to delete a group or service that something still references.
            if objs[path].get("resource_type") in ("Group", "Service"):
                for o in objs.values():
                    if o is objs[path]:
                        continue
                    blob = json.dumps({k: v for k, v in o.items() if k not in ("path", "parent_path")})
                    if f'"{path}"' in blob:
                        return self.send(400, {"error_code": 500030, "error_message":
                                               f"Cannot delete {path}: referenced by {o['path']}"})
            for k in [k for k in objs if k == path or k.startswith(path + "/")]:
                del objs[k]
            save()
            return self.send(200)


load()
srv = ThreadingHTTPServer(("127.0.0.1", port), H)
ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
ctx.load_cert_chain(cert, key)
srv.socket = ctx.wrap_socket(srv.socket, server_side=True)
srv.serve_forever()
