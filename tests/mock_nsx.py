"""A read-only stand-in for an NSX Local Manager's policy API.

  python3 tests/mock_nsx.py <dump.json> <request-log> <port> <cert.pem> <key.pem>

Serves the objects of an import-estate.py dump over HTTPS, the way the policy API
returns them, so the real vmware/nsxt provider can import and refresh them.
Every request is logged; every write is refused (except the login session), so
a test can prove that a plan or an import apply changes nothing in NSX."""
import fnmatch, json, re, ssl, sys, urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
dump = json.load(open(sys.argv[1])); log = open(sys.argv[2], "a"); port = int(sys.argv[3]); cert, key = sys.argv[4], sys.argv[5]
objs = {}
for g in dump["groups"]: objs["/policy/api/v1" + g["path"]] = dict(g, resource_type="Group", _revision=1)
for s in dump["services"]: objs["/policy/api/v1" + s["path"]] = dict(s, resource_type="Service", _revision=1)
for p in dump["policies"]:
    body = dict(p, resource_type="SecurityPolicy", _revision=1); objs["/policy/api/v1" + p["path"]] = body
    for r in p["rules"]: objs["/policy/api/v1" + r["path"]] = dict(r, resource_type="Rule", _revision=1)
class H(BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def send(self, code, body):
        data = json.dumps(body).encode(); self.send_response(code)
        self.send_header("Content-Type", "application/json"); self.send_header("Content-Length", str(len(data))); self.end_headers(); self.wfile.write(data)
    def do_GET(self):
        path = self.path.split("?")[0]; log.write(f"GET {self.path}\n"); log.flush()
        if path in ("/api/v1/node", "/api/v1/node/version"): return self.send(200, {"node_version": "4.1.2.0.0", "product_version": "4.1.2.0.0"})
        if path in objs: return self.send(200, objs[path])
        if path == "/policy/api/v1/infra/services":
            found = [o for k, o in objs.items() if "/infra/services/" in k]
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
        return self.send(404, {"error_code": 600, "error_message": f"mock: {path} not found"})
    def write(self):
        log.write(f"WRITE {self.command} {self.path}\n"); log.flush()
        if self.path.startswith("/api/session/create"):
            self.send_response(200); self.send_header("Set-Cookie", "JSESSIONID=x"); self.send_header("X-XSRF-TOKEN", "t"); self.send_header("Content-Length", "0"); self.end_headers(); return
        return self.send(500, {"error_message": "mock NSX is read-only: a plan must never write"})
    do_POST = do_PUT = do_PATCH = do_DELETE = write
srv = ThreadingHTTPServer(("127.0.0.1", port), H)
ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER); ctx.load_cert_chain(cert, key); srv.socket = ctx.wrap_socket(srv.socket, server_side=True)
srv.serve_forever()
