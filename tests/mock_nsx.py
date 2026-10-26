"""A read-only stand-in for an NSX Local Manager's policy API.

  python3 tests/mock_nsx.py <dump.json> <request-log> <port> <cert.pem> <key.pem>

Serves the objects of an import-estate.py dump over HTTPS, the way the policy API
returns them, so the real vmware/nsxt provider can import and refresh them.
Every request is logged; every write is refused (except the login session), so
a test can prove that a plan or an import apply changes nothing in NSX.

The dump is read again whenever the file changes, so a test can stand in for an
engineer changing the manager in the UI between two reads."""
import fnmatch, json, os, re, ssl, sys, urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
log = open(sys.argv[2], "a"); port = int(sys.argv[3]); cert, key = sys.argv[4], sys.argv[5]
objs = {}; loaded = None; exclude = []
def load():
    global loaded
    stamp = os.stat(sys.argv[1]).st_mtime_ns
    if stamp == loaded: return
    dump = json.load(open(sys.argv[1])); objs.clear(); loaded = stamp
    exclude[:] = dump.get("exclude_list") or []
    rev = lambda o: o.get("_revision", 1)
    for g in dump["groups"]: objs["/policy/api/v1" + g["path"]] = dict(g, resource_type="Group", _revision=rev(g))
    for s in dump["services"]: objs["/policy/api/v1" + s["path"]] = dict(s, resource_type="Service", _revision=rev(s))
    for p in dump["policies"]:
        body = dict(p, resource_type="SecurityPolicy", _revision=rev(p)); objs["/policy/api/v1" + p["path"]] = body
        for r in p["rules"]: objs["/policy/api/v1" + r["path"]] = dict(r, resource_type="Rule", _revision=rev(r))
load()
def tree():
    """Infra -> Domain -> Group, SecurityPolicy -> Rule; Infra -> Service."""
    child = lambda kind, obj, children=None: {"resource_type": f"Child{kind}", kind: dict(obj, **({"children": children} if children else {}))}
    domains = {}
    for key, o in objs.items():
        found = re.match(r"^/policy/api/v1/infra/domains/([^/]+)/", key)
        if found: domains.setdefault(found.group(1), [])
    for key, o in objs.items():
        found = re.match(r"^/policy/api/v1/infra/domains/([^/]+)/(groups|security-policies)/[^/]+$", key)
        if not found: continue
        if o["resource_type"] == "Group":
            domains[found.group(1)].append(child("Group", o))
        else:
            rules = [child("Rule", r) for k, r in objs.items() if k.startswith(key + "/rules/")]
            domains[found.group(1)].append(child("SecurityPolicy", {k: v for k, v in o.items() if k != "rules"}, rules))
    children = [child("Domain", {"id": d, "path": f"/infra/domains/{d}", "resource_type": "Domain"}, c) for d, c in sorted(domains.items())]
    children += [child("Service", o) for k, o in objs.items() if o.get("resource_type") == "Service"]
    return {"resource_type": "Infra", "id": "infra", "children": children}
class H(BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def send(self, code, body):
        data = json.dumps(body).encode(); self.send_response(code)
        self.send_header("Content-Type", "application/json"); self.send_header("Content-Length", str(len(data))); self.end_headers(); self.wfile.write(data)
    def do_GET(self):
        load()
        path = urllib.parse.unquote(self.path.split("?")[0]); log.write(f"GET {self.path}\n"); log.flush()
        if path in ("/api/v1/node", "/api/v1/node/version"): return self.send(200, {"node_version": "4.1.2.0.0", "product_version": "4.1.2.0.0"})
        # The hierarchical read: the whole tree in one call, as NSX 4.2 serves it.
        # A file <request-log>.paged makes the mock refuse it, like a manager
        # without it, so the paged read is tested too.
        if path == "/policy/api/v1/infra" and "type_filter=" in self.path:
            if os.path.exists(sys.argv[2] + ".paged"):
                return self.send(400, {"error_message": "mock: no hierarchical read"})
            return self.send(200, tree())
        if path in objs: return self.send(200, objs[path])
        if path.endswith("/statistics") and path[:-len("/statistics")] in objs:
            # Rule hit counters, from each rule's _hits in the dump.
            policy = path[:-len("/statistics")]
            rules = [o for k, o in objs.items() if k.startswith(policy + "/rules/")]
            return self.send(200, {"results": [{"statistics": {"results": [
                {"internal_rule_id": str(r.get("rule_id", r["id"])), "hit_count": r.get("_hits", 0)} for r in rules]}}]})
        if path == "/policy/api/v1/infra/settings/firewall/security/exclude-list":
            return self.send(200, {"resource_type": "PolicyExcludeList", "id": "exclude-list", "path": "/infra/settings/firewall/security/exclude-list",
                                   "members": list(exclude), "_revision": 1})
        if path == "/policy/api/v1/infra/services":
            found = [o for k, o in objs.items() if "/infra/services/" in k]
            return self.send(200, {"results": found, "result_count": len(found)})
        if path.startswith("/policy/api/v1/search") and "_last_modified_time" in urllib.parse.unquote(self.path):
            # The change watch: objects of these kinds modified since a time.
            query = urllib.parse.unquote_plus(self.path.partition("query=")[2].split("&")[0])
            kinds = re.search(r"resource_type:\(([^)]*)\)", query).group(1).split(" OR ")
            since = int(re.search(r"_last_modified_time:\[(\d+) TO", query).group(1))
            found = [o for o in objs.values() if o.get("resource_type") in kinds and (o.get("_last_modified_time") or 0) >= since]
            return self.send(200, {"results": found, "result_count": len(found)})
        if path.startswith("/policy/api/v1/search"):
            # Honour the display_name in the query, as the real search API does.
            query = urllib.parse.unquote(self.path.partition("query=")[2].split("&")[0])
            # The name runs to the first unescaped space; spaces inside it are "\ ".
            name = re.search(r"display_name:\(?\"?((?:\\.|[^\s\")&\\])+)", query)
            wanted = re.sub(r"\\(.)", r"\1", name.group(1)) if name else None
            # NSX search treats * as a wildcard; the provider asks for "<name>*"
            # and filters for the exact name itself.
            found = [o for o in objs.values() if o.get("resource_type") == "Service"
                     and (wanted is None or fnmatch.fnmatchcase(o.get("display_name", ""), wanted))]
            return self.send(200, {"results": found, "result_count": len(found)})
        # A collection (.../groups, .../security-policies): its direct children.
        children = [o for k, o in objs.items() if k.startswith(path + "/") and "/" not in k[len(path) + 1:]]
        if children:
            return self.send(200, {"results": children, "result_count": len(children)})
        return self.send(404, {"error_code": 600, "error_message": f"mock: {path} not found"})
    def write(self):
        log.write(f"WRITE {self.command} {self.path}\n"); log.flush()
        if self.path.startswith("/api/session/create"):
            self.send_response(200); self.send_header("Set-Cookie", "JSESSIONID=x"); self.send_header("X-XSRF-TOKEN", "t"); self.send_header("Content-Length", "0"); self.end_headers(); return
        # Opt-in, for the time follower's test: a file <request-log>.writable lets
        # an existing rule be updated (as switching it on or off does). Anything
        # else stays refused.
        path = urllib.parse.unquote(self.path.split("?")[0])
        if os.path.exists(sys.argv[2] + ".writable") and self.command in ("PATCH", "PUT") and objs.get(path, {}).get("resource_type") == "Rule":
            body = json.loads(self.rfile.read(int(self.headers.get("Content-Length") or 0)) or b"{}")
            log.write(f"BODY {json.dumps(body, sort_keys=True)}\n"); log.flush()
            objs[path] = dict(objs[path], **{k: v for k, v in body.items() if not k.startswith("_")}, _revision=objs[path]["_revision"] + 1)
            return self.send(200, objs[path])
        return self.send(500, {"error_message": "mock NSX is read-only: a plan must never write"})
    do_POST = do_PUT = do_PATCH = do_DELETE = write
srv = ThreadingHTTPServer(("127.0.0.1", port), H)
ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER); ctx.load_cert_chain(cert, key); srv.socket = ctx.wrap_socket(srv.socket, server_side=True)
srv.serve_forever()
