"""A stand-in for the few GitLab API calls scripts/gitlab-setup.sh makes, enough to

  python3 tests/fake_gitlab_setup.py <port> <request-log> [state.json]

see which token it stores as CI_API_TOKEN. state.json may seed "variables" and
set "no_tokens" (project access tokens unavailable). Everything else answers {}."""
import json, sys, urllib.parse
from http.server import BaseHTTPRequestHandler, HTTPServer
port, log = int(sys.argv[1]), open(sys.argv[2], "a")
st = json.load(open(sys.argv[3])) if len(sys.argv) > 3 else {}
vars_ = st.get("variables", {}); tokens = []
class H(BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def r(self, code, body):
        d = json.dumps(body).encode(); self.send_response(code); self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(d))); self.end_headers(); self.wfile.write(d)
    def form(self):
        n = int(self.headers.get("Content-Length") or 0); raw = self.rfile.read(n).decode() if n else ""
        return {k: v[-1] for k, v in urllib.parse.parse_qs(raw).items()}
    def any(self):
        u = urllib.parse.urlparse(self.path); p = u.path.replace("/api/v4", ""); f = self.form() if self.command in ("POST", "PUT") else {}
        log.write(f"{self.command} {p} {json.dumps({k: (v if k != 'value' else v[:12]) for k, v in f.items()})}\n"); log.flush()
        if p == "/user": return self.r(200, {"username": "admin"})
        if p == "/version": return self.r(200, {"version": "17.5.2"})
        if p.startswith("/projects/") and p.count("/") == 2: return self.r(200, {"id": 7, "default_branch": "main"})
        if p == "/projects/7/variables" and self.command == "POST": vars_[f["key"]] = f; return self.r(201, f)
        if p.startswith("/projects/7/variables/"):
            k = p.rsplit("/", 1)[1]
            if self.command == "GET": return self.r(200, vars_[k]) if k in vars_ else self.r(404, {"message": "404"})
            if self.command == "PUT": vars_[k] = dict(vars_.get(k, {}), **f, key=k); return self.r(200, vars_[k])
            if self.command == "DELETE": vars_.pop(k, None); return self.r(204, {})
        if p == "/projects/7/access_tokens" and self.command == "POST":
            if st.get("no_tokens"): return self.r(404, {"message": "404 Not Found"})
            tokens.append(f); return self.r(201, {"token": "glpat-REPORTER-TOKEN", "access_level": int(f["access_level"])})
        return self.r(200, {})
    do_GET = do_POST = do_PUT = do_DELETE = any
HTTPServer(("127.0.0.1", port), H).serve_forever()
