"""A stand-in for the parts of GitLab's merge request API the pipeline scripts use.

  python3 tests/fake_gitlab_api.py <port> <log>

Keeps merge requests in memory: list (filtered by state, source and target
branch), create, update (including state_event=close) and schedule a merge.
Issues too: create, and list filtered by labels and state. The
first merge call of each merge request is refused, as GitLab does until the
merge request's pipeline exists. Every call is appended to <log> as one JSON
line: method, path, headers that matter, body."""
import json, sys, urllib.parse
from http.server import BaseHTTPRequestHandler, HTTPServer

port, log = int(sys.argv[1]), sys.argv[2]
mrs: dict[int, dict] = {}
issues: list[dict] = []
merge_calls: dict[int, int] = {}


class H(BaseHTTPRequestHandler):
    def log_message(self, *a): pass

    def reply(self, code, body):
        data = json.dumps(body).encode()
        self.send_response(code); self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data))); self.end_headers(); self.wfile.write(data)

    def handle_any(self):
        url = urllib.parse.urlparse(self.path)
        length = int(self.headers.get("Content-Length") or 0)
        body = json.loads(self.rfile.read(length) or b"{}") if length else {}
        with open(log, "a") as f:
            f.write(json.dumps({"method": self.command, "path": url.path, "query": url.query,
                                "token": self.headers.get("PRIVATE-TOKEN"), "body": body}) + "\n")
        parts = url.path.rstrip("/").split("/")
        if parts[-1] == "issues" and self.command == "POST":
            issue = dict(body, iid=len(issues) + 1, state="opened", web_url=f"http://gitlab.test/issues/{len(issues) + 1}")
            issues.append(issue)
            return self.reply(201, issue)
        if parts[-1] == "issues" and self.command == "GET":
            q = urllib.parse.parse_qs(url.query)
            want = set(filter(None, q.get("labels", [""])[0].split(",")))
            state = q.get("state", ["opened"])[0]
            found = [i for i in reversed(issues) if want <= set(i.get("labels", "").split(","))
                     and state in ("all", i["state"])]
            return self.reply(200, found)
        if parts[-1] == "merge_requests" and self.command == "GET":
            q = urllib.parse.parse_qs(url.query)
            found = [m for m in mrs.values()
                     if m["state"] == q.get("state", ["opened"])[0]
                     and m["source_branch"] == q.get("source_branch", [m["source_branch"]])[0]
                     and m["target_branch"] == q.get("target_branch", [m["target_branch"]])[0]]
            return self.reply(200, found)
        if parts[-1] == "merge_requests" and self.command == "POST":
            iid = len(mrs) + 1
            mrs[iid] = dict(body, iid=iid, state="opened", web_url=f"http://gitlab.test/mr/{iid}")
            return self.reply(201, mrs[iid])
        if parts[-1] == "merge" and self.command == "PUT":
            iid = int(parts[-2])
            merge_calls[iid] = merge_calls.get(iid, 0) + 1
            if merge_calls[iid] == 1:
                return self.reply(405, {"message": "405 Method Not Allowed"})
            mrs[iid]["auto_merge"] = True
            return self.reply(200, mrs[iid])
        if parts[-2] == "merge_requests" and self.command == "PUT":
            iid = int(parts[-1])
            if body.pop("state_event", None) == "close":
                mrs[iid]["state"] = "closed"
            mrs[iid].update(body)
            return self.reply(200, mrs[iid])
        return self.reply(404, {"message": "404 Not Found"})

    do_GET = do_POST = do_PUT = handle_any


HTTPServer(("127.0.0.1", port), H).serve_forever()
