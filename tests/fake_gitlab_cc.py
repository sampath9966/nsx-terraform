"""A stand-in for the GitLab API that change control uses, with state.

  python3 tests/fake_gitlab_cc.py <port> <token> <state.json>

The state file seeds project members, the merge requests of commits and their
approvals, and pipeline jobs. Issues, notes, award emoji, wiki pages and job
plays are kept in memory. Test-only endpoints, outside the API:

  POST /__emoji/<iid>/<username>   a user gives issue <iid> a thumbs-up
  POST /__set                      merge a JSON object into the state
  GET  /__state                    the whole state, as JSON

Every API call must carry the token in a PRIVATE-TOKEN header."""
import json, sys, urllib.parse
from http.server import BaseHTTPRequestHandler, HTTPServer

port, token, seed = int(sys.argv[1]), sys.argv[2], sys.argv[3]
state = {"members": [], "commit_mrs": {}, "mr_approvals": {}, "issues": [], "notes": {}, "emoji": {},
         "wiki": {}, "pipeline_jobs": {}, "played": [], "clock": 0}
state.update(json.load(open(seed)))


def issue(iid):
    return next((i for i in state["issues"] if i["iid"] == iid), None)


class H(BaseHTTPRequestHandler):
    def log_message(self, *a): pass

    def reply(self, code, body, headers=None):
        data = json.dumps(body).encode()
        self.send_response(code); self.send_header("Content-Type", "application/json")
        for k, v in (headers or {}).items():
            self.send_header(k, v)
        self.send_header("Content-Length", str(len(data))); self.end_headers(); self.wfile.write(data)

    def body(self):
        n = int(self.headers.get("Content-Length") or 0)
        return json.loads(self.rfile.read(n) or b"{}") if n else {}

    def handle_any(self):
        url = urllib.parse.urlparse(self.path)
        q = {k: v[0] for k, v in urllib.parse.parse_qs(url.query).items()}
        parts = [urllib.parse.unquote(p) for p in url.path.strip("/").split("/")]
        if parts[0] == "__state":
            return self.reply(200, state)
        if parts[0] == "__set":
            state.update(self.body()); return self.reply(200, {})
        if parts[0] == "__emoji":
            state["emoji"].setdefault(parts[1], []).append({"name": "thumbsup", "user": {"username": parts[2]}})
            return self.reply(200, {})
        if self.headers.get("PRIVATE-TOKEN") != token:
            return self.reply(401, {"message": "401 Unauthorized"})
        # /api/v4/projects/<id>/...
        rest, method = parts[4:], self.command
        state["clock"] += 1
        if rest == ["members", "all"]:
            return self.reply(200, state["members"])
        if rest[:2] == ["repository", "commits"] and rest[3:] == ["merge_requests"]:
            return self.reply(200, state["commit_mrs"].get(rest[2], []))
        if rest[0] == "merge_requests" and rest[2:] == ["approvals"]:
            return self.reply(200, {"approved_by": [{"user": {"username": u}} for u in state["mr_approvals"].get(rest[1], [])]})
        if rest == ["issues"] and method == "GET":
            want = set(filter(None, q.get("labels", "").split(",")))
            found = [i for i in state["issues"] if want <= set(i["labels"]) and i["state"] == q.get("state", i["state"])]
            found.sort(key=lambda i: i["updated"], reverse=q.get("sort") == "desc")
            return self.reply(200, found[: int(q.get("per_page", 100))])
        if rest == ["issues"] and method == "POST":
            b = self.body()
            new = {"iid": len(state["issues"]) + 1, "title": b["title"], "description": b["description"],
                   "labels": b.get("labels", "").split(","), "state": "opened", "updated": state["clock"]}
            new["web_url"] = f"http://gitlab.test/issues/{new['iid']}"
            state["issues"].append(new)
            return self.reply(201, new)
        if rest[0] == "issues" and len(rest) == 2:
            i = issue(int(rest[1]))
            if i is None:
                return self.reply(404, {"message": "404 Not found"})
            if method == "PUT":
                b = self.body()
                if "labels" in b:
                    i["labels"] = b["labels"].split(",")
                if b.get("state_event") == "close":
                    i["state"] = "closed"
                i["updated"] = state["clock"]
            return self.reply(200, i)
        if rest[0] == "issues" and rest[2:] == ["notes"]:
            state["notes"].setdefault(rest[1], []).append(self.body()["body"])
            return self.reply(201, {})
        if rest[0] == "issues" and rest[2:] == ["award_emoji"]:
            return self.reply(200, state["emoji"].get(rest[1], []))
        if rest[0] == "wikis":
            if len(rest) == 1 and method == "POST":
                b = self.body(); slug = b["title"].replace(" ", "-")
                state["wiki"][slug] = b["content"]
                return self.reply(201, {"slug": slug, "content": b["content"]})
            slug = rest[1]
            if method == "PUT":
                state["wiki"][slug] = self.body()["content"]
                return self.reply(200, {"slug": slug, "content": state["wiki"][slug]})
            if slug not in state["wiki"]:
                return self.reply(404, {"message": "404 Wiki Page Not Found"})
            return self.reply(200, {"slug": slug, "content": state["wiki"][slug]})
        if rest[0] == "pipelines" and rest[2:] == ["jobs"]:
            jobs = state["pipeline_jobs"].get(rest[1], [])
            return self.reply(200, [j for j in jobs if j["status"] == "manual"] if q.get("scope[]") == "manual" else jobs)
        if rest[0] == "jobs" and rest[2:] == ["play"]:
            state["played"].append(int(rest[1]))
            for jobs in state["pipeline_jobs"].values():
                for j in jobs:
                    if j["id"] == int(rest[1]):
                        j["status"] = "pending"
            return self.reply(200, {"id": int(rest[1]), "web_url": f"http://gitlab.test/jobs/{rest[1]}"})
        return self.reply(404, {"message": f"404 fake: {method} {url.path}"})

    do_GET = do_POST = do_PUT = handle_any


HTTPServer(("127.0.0.1", port), H).serve_forever()
