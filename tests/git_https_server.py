"""A git smart-HTTP server over TLS, for testing pushes the way GitLab takes them.

  python3 tests/git_https_server.py <repo-root> <port> <token> <cert.pem> <key.pem> <access-log>

Serves the bare repositories under <repo-root> through 'git http-backend', and
only to "Authorization: Basic oauth2:<token>". Logs, per request, whether the
header was right and whether the token appeared in the URL (it must not)."""
import base64, os, ssl, subprocess, sys
from wsgiref.simple_server import make_server, WSGIRequestHandler
root, port, token, cert, key, log = sys.argv[1], int(sys.argv[2]), sys.argv[3], sys.argv[4], sys.argv[5], sys.argv[6]
want = "Basic " + base64.b64encode(f"oauth2:{token}".encode()).decode()
def app(environ, start):
    auth = environ.get("HTTP_AUTHORIZATION", "")
    open(log, "a").write(f"{environ['REQUEST_METHOD']} {environ['PATH_INFO']} auth={'ok' if auth == want else 'missing' if not auth else 'WRONG'} url_has_token={token in environ.get('QUERY_STRING','') + environ['PATH_INFO']}\n")
    if auth != want:
        start("401 Unauthorized", [("WWW-Authenticate", 'Basic realm="git"')]); return [b""]
    env = dict(os.environ, GIT_PROJECT_ROOT=root, GIT_HTTP_EXPORT_ALL="1", REMOTE_USER="oauth2",
               PATH_INFO=environ["PATH_INFO"], QUERY_STRING=environ.get("QUERY_STRING", ""),
               REQUEST_METHOD=environ["REQUEST_METHOD"], CONTENT_TYPE=environ.get("CONTENT_TYPE", ""))
    body = environ["wsgi.input"].read(int(environ.get("CONTENT_LENGTH") or 0))
    out = subprocess.run(["git", "http-backend"], input=body, env=env, capture_output=True).stdout
    head, _, payload = out.partition(b"\r\n\r\n")
    headers = [tuple(h.split(": ", 1)) for h in head.decode().split("\r\n") if ": " in h]
    status = next((v for k, v in headers if k == "Status"), "200 OK")
    start(status, [(k, v) for k, v in headers if k != "Status"]); return [payload]
class Q(WSGIRequestHandler):
    def log_message(self, *a): pass
httpd = make_server("127.0.0.1", port, app, handler_class=Q)
ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER); ctx.load_cert_chain(cert, key)
httpd.socket = ctx.wrap_socket(httpd.socket, server_side=True)
httpd.serve_forever()
