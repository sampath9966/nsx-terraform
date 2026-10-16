#!/usr/bin/env python3
"""Summarise pipeline jobs for tests/e2e-gitlab.sh.

  gitlab_jobs.py first-id            < pipelines.json   -> newest pipeline id
  gitlab_jobs.py status NAME...      < jobs.json        -> 'name=status ...'
  gitlab_jobs.py failed              < jobs.json        -> ids of failed jobs

Reads GitLab API JSON on stdin. Kept out of the shell script so there is no
quoting to get wrong (an inline one-liner here once made the test wait its full
timeout and report nothing).
"""
import json
import sys


def main() -> int:
    mode = sys.argv[1] if len(sys.argv) > 1 else ""
    try:
        data = json.load(sys.stdin)
    except ValueError:
        return 0  # not JSON (yet): print nothing, the caller keeps waiting
    if mode == "first-id":
        print(data[0]["id"] if isinstance(data, list) and data else "")
    elif mode == "status":
        wanted = sys.argv[2:]
        jobs = {j["name"]: j["status"] for j in data if j.get("name") in wanted}
        print(" ".join(f"{n}={jobs.get(n, 'missing')}" for n in wanted))
    elif mode == "failed":
        print(" ".join(str(j["id"]) for j in data if j.get("status") == "failed"))
    return 0


if __name__ == "__main__":
    sys.exit(main())
