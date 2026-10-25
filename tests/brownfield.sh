#!/usr/bin/env bash
# Brownfield adoption: the importer, the plan guard, hand-back, and the
# per-manager safety of scripts/tf.sh. Offline: no Terraform, no network. The
# plan fixtures have the exact shape Terraform 1.9 writes with 'show -json'.
set -uo pipefail
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
scratch
T="$SCRATCH/tree"
generate "$T" --no-examples
cd "$T" || exit 1

cat >inventory/managers.yaml <<'INV'
managers:
  gm1:
    role: gm
    host: gm.example.net
    site: global
    vcf_instance: vcf-a
    vault_path: secret/nsx/gm1
    tier: prod
  lon1:
    role: lm
    host: lon1.example.net
    site: lon1
    vcf_instance: vcf-a
    vault_path: secret/nsx/lon1
    tier: prod
  nyc1:
    role: lm
    host: nyc1.example.net
    site: nyc1
    vcf_instance: vcf-a
    vault_path: secret/nsx/nyc1
    tier: prod
INV
mkdir -p reports

# --- a live estate, as the policy API returns it ---------------------------------
python3 - <<'PY'
import json
D = "/infra/domains/default"; SV = "/infra/services"
cond = lambda v: {"resource_type": "Condition", "key": "Tag", "member_type": "VirtualMachine", "operator": "EQUALS", "value": v}
def g(i, expr, **kw): return dict({"id": i, "path": f"{D}/groups/{i}", "display_name": i, "expression": expr}, **kw)
groups = [
    g("App-Web", [cond("app|web")], tags=[{"scope": "owner", "tag": "team-a"}]),
    g("App-DB", [cond("app|db")]),
    g("App-All", [{"resource_type": "PathExpression", "paths": [f"{D}/groups/App-Web", f"{D}/groups/App-DB"]}]),
    g("Jump", [{"resource_type": "IPAddressExpression", "ip_addresses": ["10.1.1.10"]}]),
    # Membership by Active Directory group (identity firewall): not representable.
    g("Mac", [{"resource_type": "IdentityGroupExpression", "identity_groups": [{"distinguished_name": "CN=ops,DC=corp"}]}]),
    g("Nests-Mac", [{"resource_type": "PathExpression", "paths": [f"{D}/groups/Mac"]}]),
    g("Other", [cond("app|other")]),
]
services = [
    {"id": "App-8443", "path": f"{SV}/App-8443", "display_name": "App 8443",
     "service_entries": [{"resource_type": "L4PortSetServiceEntry", "display_name": "TCP-8443", "l4_protocol": "TCP", "destination_ports": ["8443"]}]},
    {"id": "HTTPS", "path": f"{SV}/HTTPS", "display_name": "HTTPS", "_system_owned": True, "service_entries": []},
    {"id": "GRE", "path": f"{SV}/GRE", "display_name": "GRE", "service_entries": [{"resource_type": "NestedServiceServiceEntry", "nested_service_path": "/infra/services/HTTPS"}]},
]
def r(p, i, src, dst, svc, seq, **kw):
    return dict({"id": i, "path": f"{D}/security-policies/{p}/rules/{i}", "display_name": i, "sequence_number": seq, "action": "ALLOW",
                 "direction": "IN_OUT", "ip_protocol": "IPV4_IPV6", "logged": True, "source_groups": src, "destination_groups": dst,
                 "services": svc, "scope": [f"{D}/groups/App-All"], "profiles": ["ANY"]}, **kw)
def pol(i, rules, scope, **kw):
    return dict({"id": i, "path": f"{D}/security-policies/{i}", "display_name": i, "category": "Application", "sequence_number": 10,
                 "stateful": True, "scope": scope, "rules": rules}, **kw)
policies = [
    pol("legacy-app", [
        r("legacy-app", "web-to-db", [f"{D}/groups/App-Web"], [f"{D}/groups/App-DB"], [f"{SV}/App-8443"], 10,
          notes="CHG-1", tag="LBL", tags=[{"scope": "chg", "tag": "1"}]),
        r("legacy-app", "jump-https", [f"{D}/groups/Jump"], [f"{D}/groups/App-All"], [f"{SV}/HTTPS"], 20, profiles=["/infra/context-profiles/SSL"]),
        r("legacy-app", "inline", [f"{D}/groups/App-Web"], [f"{D}/groups/App-DB"], ["ANY"], 30,
          service_entries=[{"resource_type": "L4PortSetServiceEntry", "l4_protocol": "UDP", "destination_ports": ["161"]}]),
        r("legacy-app", "printers", [f"{D}/groups/App-Web"], [f"{D}/groups/Nests-Mac"], ["ANY"], 40),
        r("legacy-app", "gre", [f"{D}/groups/App-Web"], [f"{D}/groups/App-DB"], [f"{SV}/GRE"], 50),
    ], [f"{D}/groups/App-All"], comments="NetOps", tags=[{"scope": "owner", "tag": "netops"}]),
    pol("other-app", [r("other-app", "x", [f"{D}/groups/Other"], [f"{D}/groups/App-Web"], ["ANY"], 10)], [f"{D}/groups/App-All"]),
    pol("mac-scoped", [r("mac-scoped", "m", [f"{D}/groups/App-Web"], [f"{D}/groups/App-DB"], ["ANY"], 10)], [f"{D}/groups/Mac"]),
    pol("fresh-app", [r("fresh-app", "f1", [f"{D}/groups/App-Web"], [f"{D}/groups/App-DB"], ["ANY"], 10)], [f"{D}/groups/App-All"]),
    pol("Default-Layer3", [], ["ANY"], _system_owned=True),
]
json.dump({"groups": groups, "services": services, "policies": policies, "domain": "default"}, open("reports/lon1-raw.json", "w"))
PY

imp() { python3 scripts/import-estate.py --site lon1 --from-dump reports/lon1-raw.json "$@" 2>&1; }

echo "importer: one policy at a time"
out="$(imp --policy legacy-app)"
check "the tranche writes its own files" bash -c 'test -f data/groups/imported-lon1-legacy-app.yaml && test -f data/policies/legacy-app.yaml && test -f stacks/local-security/import-lon1-legacy-app.tf'
G="$(cat data/groups/imported-lon1-legacy-app.yaml)"
check "only the groups the policy needs, nested ones included" bash -c 'for k in App-Web App-DB App-All Jump; do grep -q "^  $k:" <<<"$1" || exit 1; done; ! grep -q "^  Other:" <<<"$1"' _ "$G"
check "groups keep their tags" grep -q "tag: team-a" <<<"$G"
S="$(cat data/services/imported-lon1-legacy-app.yaml)"
check "custom services keep their entry names" grep -q "display_name: TCP-8443" <<<"$S"
check "a site-local service is scoped to its site" grep -q "sites: \[lon1\]" <<<"$S"
check "predefined services are referenced, not copied" grep -q "HTTPS: HTTPS" <<<"$S"
P="$(cat data/policies/legacy-app.yaml)"
check "rules keep notes, log label, context profiles and tags" bash -c 'grep -q "notes: CHG-1" <<<"$1" && grep -q "log_label: LBL" <<<"$1" && grep -q "/infra/context-profiles/SSL" <<<"$1" && grep -q "tag: \"1\"\|tag: 1" <<<"$1"' _ "$P"
check "the policy keeps its comments and tags" bash -c 'grep -q "comments: NetOps" <<<"$1" && grep -q "tag: netops" <<<"$1"' _ "$P"
I="$(cat stacks/local-security/import-lon1-legacy-app.tf)"
check "import blocks are gated on the site" bash -c '[ "$(grep -c "var.site == \"lon1\"" <<<"$1")" -eq 5 ]' _ "$I"
check "custom services are imported, not created" grep -q "module.services.nsxt_policy_service.this\[each.key\]" <<<"$I"
check "rules are imported into their policy" grep -q "each.value.policy" <<<"$I"

echo "importer: never lossy"
check "an identity (AD) group is not adopted, and says why" grep -q "group Mac: membership by IdentityGroupExpression" <<<"$out"
check "a group nesting it is not adopted" grep -q "group Nests-Mac: nests Mac" <<<"$out"
check "a service with an entry type that cannot be represented is not adopted" grep -q "service GRE: service entries of type NestedServiceServiceEntry" <<<"$out"
check "a rule with ports written in it is adopted" bash -c '! grep -q "rule legacy-app/inline" <<<"$1"' _ "$out"
check "rules using unadoptable objects stay in the UI" bash -c 'grep -q "rule legacy-app/printers: uses Nests-Mac" <<<"$1" && grep -q "rule legacy-app/gre: uses GRE" <<<"$1"' _ "$out"
check "...with the rest of the policy" bash -c 'grep -q "^  web-to-db:" <<<"$1" && grep -q "^  jump-https:" <<<"$1" && grep -q "^  inline:" <<<"$1"' _ "$P"
check "a requested policy whose Apply To is unadoptable is refused, nothing written" bash -c '! out="$(python3 scripts/import-estate.py --site lon1 --from-dump reports/lon1-raw.json --policy mac-scoped 2>&1)" && grep -q "Nothing was written" <<<"$out" && ! test -f data/policies/mac-scoped.yaml'
check "the result validates" bash -c 'python3 scripts/validate-data.py >/dev/null 2>&1 || python3 scripts/validate-data.py 2>&1 | grep -q "0 error"'

echo "importer: the second piece"
out2="$(imp --policy other-app)"
check "objects already in data/ are not adopted again" bash -c 'grep -q "MANAGED   group App-Web" <<<"$1" && grep -q "MANAGED   group App-All" <<<"$1"' _ "$out2"
check "only the new group is in the second tranche" bash -c 'grep -q "^  Other:" data/groups/imported-lon1-other-app.yaml && ! grep -q "^  App-Web:" data/groups/imported-lon1-other-app.yaml'
check "re-running a finished tranche writes nothing" bash -c '! grep -q "  wrote " <<<"$(python3 scripts/import-estate.py --site lon1 --from-dump reports/lon1-raw.json --policy legacy-app 2>&1)"'
check "an unknown policy is an error" bash -c '! python3 scripts/import-estate.py --site lon1 --from-dump reports/lon1-raw.json --policy nope >/dev/null 2>&1'
check "a system-owned policy is refused" bash -c '! python3 scripts/import-estate.py --site lon1 --from-dump reports/lon1-raw.json --policy Default-Layer3 >/dev/null 2>&1'

echo "importer: reading a large estate"
check "capture follows the API cursor across pages" python3 - <<'PY'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("imp", "scripts/import-estate.py")
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
calls = []
def fake(host, path, user, password, insecure):
    calls.append(path)
    if path.endswith("/groups"): return {"results": [{"id": "a"}], "cursor": "c1"}
    if "cursor=c1" in path: return {"results": [{"id": "b"}], "cursor": "c2"}
    if "cursor=c2" in path: return {"results": [{"id": "c"}]}
    return {"results": []}
m.api_get = fake
estate = m.fetch_estate("h", "u", "p", "/policy/api/v1/infra", "default", False)
sys.exit(0 if [g["id"] for g in estate["groups"]] == ["a", "b", "c"] else 1)
PY

echo "importer: capture over TLS trusts the manager's own CA"
for ca in mine other; do
	openssl req -x509 -newkey rsa:2048 -nodes -keyout "$SCRATCH/$ca.key" -out "$SCRATCH/$ca-ca.pem" -days 1 -subj "/CN=$ca CA" >/dev/null 2>&1
done
openssl req -newkey rsa:2048 -nodes -keyout "$SCRATCH/srv.key" -out "$SCRATCH/srv.csr" -subj "/CN=127.0.0.1" >/dev/null 2>&1
printf 'subjectAltName=IP:127.0.0.1\n' >"$SCRATCH/ext.cnf"
openssl x509 -req -in "$SCRATCH/srv.csr" -CA "$SCRATCH/mine-ca.pem" -CAkey "$SCRATCH/mine.key" -CAcreateserial \
	-out "$SCRATCH/srv.pem" -days 1 -extfile "$SCRATCH/ext.cnf" >/dev/null 2>&1
port=$((20000 + RANDOM % 20000))
python3 "$REPO/tests/mock_nsx.py" reports/lon1-raw.json "$SCRATCH/req.log" "$port" "$SCRATCH/srv.pem" "$SCRATCH/srv.key" &
mock=$!
sleep 1
capture() { env -u SSL_CERT_FILE -u NSX_CA_FILE NSXT_MANAGER_HOST="127.0.0.1:$port" NSXT_USERNAME=u NSXT_PASSWORD=p "$@" \
	python3 scripts/import-estate.py --site lon1 --dump-only "$SCRATCH/cap.json" 2>&1; }
check "with NSX_CA_FILE_<SITE> the capture verifies the manager and reads it" grep -q "wrote" <<<"$(capture NSX_CA_FILE_LON1="$SCRATCH/mine-ca.pem")"
check "...and gets the whole estate" python3 -c "import json,sys;d=json.load(open(sys.argv[1]));sys.exit(0 if len(d['groups'])==7 and len(d['policies'])==5 else 1)" "$SCRATCH/cap.json"
check "the shared NSX_CA_FILE works too" grep -q "wrote" <<<"$(capture NSX_CA_FILE="$SCRATCH/mine-ca.pem")"
out="$(capture)"
check "without the CA it refuses, and says which variable to set" bash -c 'grep -q "does not trust" <<<"$1" && grep -q "NSX_CA_FILE_LON1" <<<"$1"' _ "$out"
check "another CA is not accepted" bash -c '! grep -q "wrote" <<<"$1"' _ "$(capture NSX_CA_FILE_LON1="$SCRATCH/other-ca.pem")"
out="$(capture NSXT_ALLOW_UNVERIFIED_SSL=true)"
check "with NSXT_ALLOW_UNVERIFIED_SSL, as for the provider, the read goes through, with a warning" bash -c 'grep -q "wrote" <<<"$1" && grep -q "TLS verification of 127.0.0.1:[0-9]* is OFF" <<<"$1"' _ "$out"

echo "adopting from the pipeline (scripts/adopt.sh)"
git init -q -b main && git_quiet add -A && git_quiet commit -m baseline
git clone -q --bare . "$SCRATCH/remote.git"
sed -i "s/host: lon1.example.net/host: 127.0.0.1:$port/" inventory/managers.yaml && git_quiet commit -am "mock manager"
git_quiet push -q "$SCRATCH/remote.git" main
api_port=$((20000 + RANDOM % 20000))
python3 - "$api_port" "$SCRATCH/mr.json" <<'PY2' &
import http.server, sys
port, out = int(sys.argv[1]), sys.argv[2]
class H(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def do_POST(self):
        body = self.rfile.read(int(self.headers["Content-Length"]))
        open(out, "wb").write(body)
        open(out + ".headers", "w").write(str(self.headers))
        data = b'{"web_url": "http://gitlab.test/mr/1"}'
        self.send_response(201); self.send_header("Content-Length", str(len(data))); self.end_headers(); self.wfile.write(data)
http.server.HTTPServer(("127.0.0.1", port), H).serve_forever()
PY2
api=$!
sleep 1
adopt() { env -u SSL_CERT_FILE -u NSX_CA_FILE NSX_CA_FILE_LON1="$SCRATCH/mine-ca.pem" NSX_PLAN_USERNAME=u NSX_PLAN_PASSWORD=p \
	NSX_ADOPT_REMOTE="$SCRATCH/remote.git" NSX_ADOPT_TOKEN=SECRET-ADOPT-TOKEN CI_API_V4_URL="http://127.0.0.1:$api_port/api/v4" \
	CI_PROJECT_ID=7 CI_DEFAULT_BRANCH=main ADOPT_SITE=lon1 "$@" scripts/adopt.sh 2>&1; }
out="$(adopt)"
check "a survey lists the policies and their status" bash -c 'grep -q "policy/policies on lon1" <<<"$1" && grep -q "fresh-app" <<<"$1" && grep -q "not adoptable: Apply To uses Mac" <<<"$1"' _ "$out"
check "...and changes nothing" bash -c '[ -z "$(git status --porcelain)" ] && [ "$(git -C "$1" branch --list "adopt/*")" = "" ]' _ "$SCRATCH/remote.git"
out="$(adopt ADOPT_POLICY=fresh-app)"
check "an adoption pushes a branch adopt/<site>-<tranche>" git -C "$SCRATCH/remote.git" rev-parse -q --verify refs/heads/adopt/lon1-fresh-app
files="$(git -C "$SCRATCH/remote.git" diff --name-only main adopt/lon1-fresh-app)"
check "...holding the policy and its site-gated import file" bash -c 'grep -q "^data/policies/fresh-app.yaml$" <<<"$1" && grep -q "^stacks/local-security/import-lon1-fresh-app.tf$" <<<"$1"' _ "$files"
check "...and nothing already managed" bash -c '! grep -q "data/groups" <<<"$1"' _ "$files"
check "the capture is never committed" bash -c '! git -C "$1" log --all --name-only --format= | grep -qiE "capture|raw|dump"' _ "$SCRATCH/remote.git"
check "a merge request is opened against the default branch" python3 -c "import json,sys;d=json.load(open(sys.argv[1]));sys.exit(0 if d['source_branch']=='adopt/lon1-fresh-app' and d['target_branch']=='main' and 'pure import' in d['description'] else 1)" "$SCRATCH/mr.json"
check "...with the token in a header" grep -q "PRIVATE-TOKEN: SECRET-ADOPT-TOKEN" "$SCRATCH/mr.json.headers"
check "the token never appears in the job output" bash -c '! grep -q SECRET-ADOPT-TOKEN <<<"$1"' _ "$out"
check "the job prints the merge request" grep -q "merge request: http://gitlab.test/mr/1" <<<"$out"
git_quiet checkout main
rm -f "$SCRATCH/mr.json"
out="$(adopt ADOPT_POLICY=legacy-app)"
check "adopting what is already managed opens nothing" bash -c 'grep -q "Nothing to adopt" <<<"$1" && ! test -e "$2"' _ "$out" "$SCRATCH/mr.json"
git_quiet checkout main
out="$(adopt ADOPT_POLICY=fresh-app)"
check "the same tranche again is refused while its branch exists" grep -q "an adoption of this tranche is open" <<<"$out"
check "without a site it refuses" grep -q "ADOPT_SITE is not set" <<<"$(env -u ADOPT_SITE scripts/adopt.sh 2>&1)"
git_quiet checkout main

# The real push path: HTTPS to a git server with its own CA, the token in a
# header, and a misleading GIT_SSL_CAINFO inherited from the environment.
mkdir -p "$SCRATCH/srv/grp"
git clone -q --bare "$SCRATCH/remote.git" "$SCRATCH/srv/grp/proj.git"
git -C "$SCRATCH/srv/grp/proj.git" config http.receivepack true
git_port=$((20000 + RANDOM % 20000))
python3 "$REPO/tests/git_https_server.py" "$SCRATCH/srv" "$git_port" SECRET-ADOPT-TOKEN "$SCRATCH/srv.pem" "$SCRATCH/srv.key" "$SCRATCH/git.log" &
gitsrv=$!
sleep 1
https_adopt() { env -u SSL_CERT_FILE -u NSX_CA_FILE -u NSX_ADOPT_REMOTE NSX_CA_FILE_LON1="$SCRATCH/mine-ca.pem" \
	NSX_PLAN_USERNAME=u NSX_PLAN_PASSWORD=p NSX_ADOPT_TOKEN=SECRET-ADOPT-TOKEN \
	CI_SERVER_URL="https://127.0.0.1:$git_port" CI_PROJECT_PATH=grp/proj GIT_SSL_CAINFO="$SCRATCH/other-ca.pem" \
	CI_API_V4_URL="http://127.0.0.1:$api_port/api/v4" CI_PROJECT_ID=7 CI_DEFAULT_BRANCH=main ADOPT_SITE=lon1 \
	"$@" scripts/adopt.sh 2>&1; }
out="$(https_adopt CI_SERVER_TLS_CA_FILE="$SCRATCH/mine-ca.pem" ADOPT_POLICY=fresh-app ADOPT_TRANCHE=https)"
check "over HTTPS, with GitLab's CA, the branch is pushed" git -C "$SCRATCH/srv/grp/proj.git" rev-parse -q --verify refs/heads/adopt/lon1-https
check "...authenticated by header, never by URL" bash -c 'grep -q "auth=ok" "$1" && ! grep -q "url_has_token=True" "$1"' _ "$SCRATCH/git.log"
check "...despite an inherited GIT_SSL_CAINFO" grep -q "merge request:" <<<"$out"
git_quiet checkout main
out="$(https_adopt ADOPT_POLICY=fresh-app ADOPT_TRANCHE=nocert)"
check "without GitLab's CA the push fails; verification is not skipped" bash -c '! git -C "$1" rev-parse -q --verify refs/heads/adopt/lon1-nocert && grep -q "could not push" <<<"$2"' _ "$SCRATCH/srv/grp/proj.git" "$out"
git_quiet checkout main
kill "$gitsrv" 2>/dev/null
kill "$api" 2>/dev/null

echo "mirror mode (scripts/mirror.sh): a manager still run from the UI"
sed -i '/^  lon1:$/a\    mode: mirror' inventory/managers.yaml
git_quiet commit -am "lon1 in mirror mode"
git_quiet push -q "$SCRATCH/remote.git" main
gl_port=$((20000 + RANDOM % 20000))
python3 "$REPO/tests/fake_gitlab_api.py" "$gl_port" "$SCRATCH/gl.log" &
gl=$!
sleep 1
: >"$SCRATCH/req.log"
mirror() { env -u SSL_CERT_FILE -u NSX_CA_FILE NSX_CA_FILE_LON1="$SCRATCH/mine-ca.pem" NSX_PLAN_USERNAME=u NSX_PLAN_PASSWORD=p \
	NSX_ADOPT_REMOTE="$SCRATCH/remote.git" NSX_ADOPT_TOKEN=SECRET-ADOPT-TOKEN CI_API_V4_URL="http://127.0.0.1:$gl_port/api/v4" \
	CI_PROJECT_ID=7 CI_DEFAULT_BRANCH=main MIRROR_RETRY_SLEEP=0 MIRROR_SITE=lon1 "$@" scripts/mirror.sh 2>&1; }
posts() { grep -c '"method": "POST"' "$SCRATCH/gl.log" || true; }
remote_files() { git -C "$SCRATCH/remote.git" diff --name-status main mirror/lon1; }
head_before="$(git rev-parse HEAD)"

out="$(mirror)"
check "the first sync pushes mirror/lon1" git -C "$SCRATCH/remote.git" rev-parse -q --verify refs/heads/mirror/lon1
files="$(remote_files)"
check "...with every adoptable object not declared anywhere else" bash -c 'grep -q "^A	data/policies/fresh-app.yaml" <<<"$1" && grep -q "^A	stacks/local-security/import-lon1-mirror.tf" <<<"$1"' _ "$files"
check "...each file marked as the mirror's own" bash -c 'git -C "$1" show mirror/lon1:data/policies/fresh-app.yaml | head -1 | grep -qx "# nsx-mirror: lon1"' _ "$SCRATCH/remote.git"
check "objects another file declares are left to it" bash -c '! grep -q "other-app\|legacy-app\|data/groups" <<<"$1" && grep -q "MANAGED   policy other-app" <<<"$2" && grep -q "MANAGED   group App-Web" <<<"$2"' _ "$files" "$out"
check "objects that cannot be represented stay in the UI, reported" grep -q "NOT ADOPTED  policy mac-scoped" <<<"$out"
check "the first copy is the baseline: no drift issue" bash -c '! grep -q "/issues" "$1" && grep -q "first copy of lon1, the baseline" <<<"$2"' _ "$SCRATCH/gl.log" "$out"
check "a merge request is opened for it" python3 -c "import json,sys;l=[json.loads(x) for x in open(sys.argv[1])];p=[x for x in l if x['method']=='POST'];sys.exit(0 if len(p)==1 and p[0]['body']['source_branch']=='mirror/lon1' and p[0]['body']['title']=='Mirror lon1 from NSX' and 'Nothing is applied' in p[0]['body']['description'] else 1)" "$SCRATCH/gl.log"
check "...with the token in a header, never in the output" bash -c 'grep -q "\"token\": \"SECRET-ADOPT-TOKEN\"" "$1" && ! grep -q SECRET-ADOPT-TOKEN <<<"$2"' _ "$SCRATCH/gl.log" "$out"
check "the capture is never committed" bash -c '! git -C "$1" log --all --name-only --format= | grep -qiE "capture|raw|dump"' _ "$SCRATCH/remote.git"
check "the job leaves the checkout where it found it" test "$(git rev-parse HEAD)" = "$head_before"
tree1="$(git -C "$SCRATCH/remote.git" rev-parse "mirror/lon1^{tree}")"

out="$(mirror)"
check "a second sync before the merge updates the same merge request" bash -c '[ "$(grep -c "\"method\": \"POST\"" "$1")" = 1 ] && grep -q "\"method\": \"PUT\", \"path\": \"/api/v4/projects/7/merge_requests/1\"" "$1" && grep -q "updated merge request !1" <<<"$2"' _ "$SCRATCH/gl.log" "$out"
check "...with byte-identical content: an unchanged manager gives the same files" test "$(git -C "$SCRATCH/remote.git" rev-parse "mirror/lon1^{tree}")" = "$tree1"

merge_mirror() { # the merge request is merged
	git -C "$SCRATCH/remote.git" update-ref refs/heads/main refs/heads/mirror/lon1
	git_quiet fetch -q "$SCRATCH/remote.git" main
	git_quiet checkout -q -B main FETCH_HEAD
}
merge_mirror
out="$(mirror)"
check "once merged, an unchanged manager means nothing to do" grep -q "lon1 matches the repository: nothing to do" <<<"$out"
check "...and a merge request still open for it is closed" grep -q "closed merge request !1" <<<"$out"
check "...without pushing anything" test "$(git -C "$SCRATCH/remote.git" rev-parse "mirror/lon1^{tree}")" = "$tree1"

# Engineers change the manager in the UI: a new group and policy, an edited rule.
python3 - <<'PY'
import json
d = json.load(open("reports/lon1-raw.json"))
D = "/infra/domains/default"
import time
now = int(time.time() * 1000)
d["groups"].append({"id": "New-G", "path": f"{D}/groups/New-G", "display_name": "New-G",
                    "_last_modified_user": "alice", "_last_modified_time": now,
                    "expression": [{"resource_type": "IPAddressExpression", "ip_addresses": ["10.9.9.9"]}]})
# Untouched for years: an object only a newer importer can take is not drift.
d["groups"].append({"id": "Old-G", "path": f"{D}/groups/Old-G", "display_name": "Old-G",
                    "_last_modified_user": "admin", "_last_modified_time": 1500000000000,
                    "expression": [{"resource_type": "IPAddressExpression", "ip_addresses": ["10.8.8.8"]}]})
fresh = next(p for p in d["policies"] if p["id"] == "fresh-app")
fresh["rules"][0]["action"] = "DROP"
fresh["rules"][0]["_last_modified_user"] = "bob"
fresh["rules"][0]["_last_modified_time"] = now
new = json.loads(json.dumps(fresh).replace("fresh-app", "new-app"))
new["rules"][0]["source_groups"] = [f"{D}/groups/New-G"]
d["policies"].append(new)
json.dump(d, open("reports/lon1-raw.json", "w"))
PY
out="$(mirror MIRROR_AUTO_MERGE=1)"
files="$(remote_files)"
check "a group and a policy added in the UI are added" bash -c 'grep -q "^A	data/groups/imported-lon1-mirror.yaml" <<<"$1" && grep -q "^A	data/policies/new-app.yaml" <<<"$1"' _ "$files"
check "...with their import blocks" bash -c 'f="$(git -C "$1" show mirror/lon1:stacks/local-security/import-lon1-mirror.tf)"; grep -q New-G <<<"$f" && grep -q new-app <<<"$f"' _ "$SCRATCH/remote.git"
check "a rule changed in the UI follows" bash -c 'grep -q "^M	data/policies/fresh-app.yaml" <<<"$1" && git -C "$2" show mirror/lon1:data/policies/fresh-app.yaml | grep -q "action: DROP"' _ "$files" "$SCRATCH/remote.git"
check "a new merge request lists the changes" python3 -c "import json,sys;l=[json.loads(x) for x in open(sys.argv[1])];p=[x for x in l if x['method']=='POST' and x['path'].endswith('/merge_requests')];d=p[-1]['body']['description'];sys.exit(0 if len(p)==2 and '| added | \`data/policies/new-app.yaml\` |' in d and '| changed | \`data/policies/fresh-app.yaml\` |' in d else 1)" "$SCRATCH/gl.log"
check "MIRROR_AUTO_MERGE=1 sets it to merge when its pipeline passes, retrying until GitLab accepts" bash -c 'grep -q "set to merge when its pipeline passes" <<<"$1" && [ "$(grep -c "/merge_requests/2/merge" "$2")" = 2 ]' _ "$out" "$SCRATCH/gl.log"
check "the mirrored data passes validation" python3 scripts/validate-data.py
issue() { python3 -c "import json,sys;l=[json.loads(x) for x in open(sys.argv[1])];p=[x['body'] for x in l if x['method']=='POST' and x['path'].endswith('/issues')];print(json.dumps(p[-1], ensure_ascii=False) if p else '{}');print(len(p))" "$SCRATCH/gl.log"; }
I="$(issue)"
check "UI changes raise one drift issue, labelled for the site" bash -c 'grep -q "\"labels\": \"nsx-drift,site:lon1\"" <<<"$1" && tail -1 <<<"$1" | grep -qx 1' _ "$I"
check "...listing what was added and changed, by whom" bash -c 'grep -q "| added | .group New-G. |  | alice |" <<<"$1" && grep -q "| added | .policy new-app." <<<"$1" && grep -q "| changed | .rule fresh-app/[^.]*. | action ALLOW → DROP | bob |" <<<"$1"' _ "$I"
check "...but not an old object a newer importer takes for the first time" bash -c '! grep -q "Old-G" <<<"$1"' _ "$I"
check "...with the investigation checklist" grep -q "Who made each change, and why" <<<"$I"
out="$(mirror)"
check "the same changes seen again are not raised again" bash -c '[ "$2" = 1 ] && grep -q "already in an nsx-drift issue" <<<"$1"' _ "$out" "$(issue | tail -1)"
merge_mirror

# ...and later delete them again.
python3 - <<'PY'
import json
d = json.load(open("reports/lon1-raw.json"))
d["groups"] = [g for g in d["groups"] if g["id"] not in ("New-G", "Old-G")]
d["policies"] = [p for p in d["policies"] if p["id"] != "new-app"]
json.dump(d, open("reports/lon1-raw.json", "w"))
PY
out="$(mirror)"
files="$(remote_files)"
I="$(issue)"
check "deletions raise a new drift issue; a policy's rules go with it" bash -c 'tail -1 <<<"$1" | grep -qx 2 && grep -q "| deleted | .policy new-app. | with its 1 rule(s) |" <<<"$1" && grep -q "| deleted | .group New-G." <<<"$1" && ! grep -q "rule new-app/" <<<"$1"' _ "$I"
check "a policy and a group deleted in the UI are deleted from the repository" bash -c 'grep -q "^D	data/policies/new-app.yaml" <<<"$1" && grep -q "^D	data/groups/imported-lon1-mirror.yaml" <<<"$1"' _ "$files"
check "...and from the import blocks" bash -c '! git -C "$1" show mirror/lon1:stacks/local-security/import-lon1-mirror.tf | grep -q "New-G\|new-app"' _ "$SCRATCH/remote.git"
check "...and from the manifest" bash -c '! git -C "$1" show mirror/lon1:data/.import-manifest.json | grep -q new-app' _ "$SCRATCH/remote.git"

# A large manager: its file list and report are over the kernel's 128 KiB limit
# for one environment variable or argument, and over what a description holds.
python3 - <<'PY'
import json
d = json.load(open("reports/lon1-raw.json"))
fresh = next(p for p in d["policies"] if p["id"] == "fresh-app")
for i in range(4000):
    d["policies"].append(json.loads(json.dumps(fresh).replace("fresh-app", f"bulk-application-policy-{i:04d}")))
json.dump(d, open("reports/lon1-raw.json", "w"))
PY
out="$(mirror)"
printf '%s\n' "$out" >"$SCRATCH/large.out"
check "a large manager is mirrored: its text reaches the merge request through files, not the environment" bash -c '! grep -q "Argument list too long" "$1" && grep -q "updated merge request" "$1" && git -C "$2" show mirror/lon1:data/policies/bulk-application-policy-3999.yaml >/dev/null' _ "$SCRATCH/large.out" "$SCRATCH/remote.git"
check "...and the merge request lists the first 400 files, pointing at the job log for the rest" python3 -c "import json,sys;l=[json.loads(x) for x in open(sys.argv[1])];b=[x for x in l if x['method'] in ('POST','PUT') and '/merge_requests' in x['path'] and 'description' in (x.get('body') or {})][-1]['body']['description'];sys.exit(0 if 'more: see the mirror job' in b and len(b) < 1000000 else 1)" "$SCRATCH/gl.log"
python3 - <<'PY'
import json
d = json.load(open("reports/lon1-raw.json"))
d["policies"] = [p for p in d["policies"] if not p["id"].startswith("bulk-application-policy-")]
json.dump(d, open("reports/lon1-raw.json", "w"))
PY

out="$(mirror MIRROR_SITE=nyc1)"
rc=$?
check "a manager in mode: managed is refused, and the job fails" bash -c '[ "$2" -ne 0 ] && grep -q "nyc1 is in mode: managed" <<<"$1" && ! git -C "$3" rev-parse -q --verify refs/heads/mirror/nyc1' _ "$out" "$rc" "$SCRATCH/remote.git"
out="$(mirror MIRROR_SITE=all)"
check "MIRROR_SITE=all takes every manager in mode: mirror, and only those" bash -c 'grep -q "=== lon1" <<<"$1" && ! grep -q "=== nyc1" <<<"$1" && ! grep -q "=== gm1" <<<"$1"' _ "$out"
check "without MIRROR_SITE it refuses" grep -q "MIRROR_SITE is not set" <<<"$(mirror MIRROR_SITE=)"
sed -i '/^    mode: mirror$/d' inventory/managers.yaml
out="$(mirror MIRROR_SITE=all)"
check "MIRROR_SITE=all with no mirror manager lists each manager's mode, and points at the inventory" bash -c 'grep -q "  lon1: managed" <<<"$1" && grep -q "  nyc1: managed" <<<"$1" && grep -q "add .mode: mirror. to each manager to copy, in inventory/managers.yaml" <<<"$1"' _ "$out"
check "a leftover NSX_MODE_ variable stops the job: the mode comes from the inventory only" grep -q "comes from inventory/managers.yaml only" <<<"$(mirror MIRROR_SITE=all NSX_MODE_LON1=mirror)"
git_quiet checkout -q -- inventory/managers.yaml
writes="$(grep WRITE "$SCRATCH/req.log" | grep -vc "/api/session/create" || true)"
check "mirroring only reads NSX" test "$writes" -eq 0
kill "$gl" 2>/dev/null
git_quiet checkout -q main
sed -i '/^    mode: mirror$/d' inventory/managers.yaml
git_quiet commit -qam "lon1 back to managed for the tests below"

kill "$mock" 2>/dev/null
wait "$mock" 2>/dev/null

echo "plan-guard"
plan() { # plan <file> <json for resource_changes>
	printf '{"format_version":"1.2","terraform_version":"1.9.8","resource_changes":%s}\n' "$2" >"$1"
}
rc_() { local f="$1" s="$2"; shift 2; python3 scripts/plan-guard.py --site "$s" --stack local-security "$f" >/dev/null 2>&1; echo $?; }
A='module.policies[\"p\"].nsxt_policy_security_policy_rule.this[\"r\"]'
plan "$SCRATCH/import.json" "[{\"address\":\"$A\",\"mode\":\"managed\",\"change\":{\"actions\":[\"no-op\"],\"importing\":{\"id\":\"x\"}}}]"
plan "$SCRATCH/import-update.json" "[{\"address\":\"$A\",\"mode\":\"managed\",\"change\":{\"actions\":[\"update\"],\"importing\":{\"id\":\"x\"}}}]"
plan "$SCRATCH/import-create.json" "[{\"address\":\"$A\",\"mode\":\"managed\",\"change\":{\"actions\":[\"no-op\"],\"importing\":{\"id\":\"x\"}}},{\"address\":\"b.c\",\"mode\":\"managed\",\"change\":{\"actions\":[\"create\"]}}]"
plan "$SCRATCH/create-update.json" "[{\"address\":\"a.b\",\"mode\":\"managed\",\"change\":{\"actions\":[\"create\"]}},{\"address\":\"c.d\",\"mode\":\"managed\",\"change\":{\"actions\":[\"update\"]}},{\"address\":\"data.x.y\",\"mode\":\"data\",\"change\":{\"actions\":[\"read\"]}}]"
plan "$SCRATCH/delete.json" "[{\"address\":\"$A\",\"mode\":\"managed\",\"change\":{\"actions\":[\"delete\"]}}]"
plan "$SCRATCH/replace.json" "[{\"address\":\"$A\",\"mode\":\"managed\",\"change\":{\"actions\":[\"delete\",\"create\"]}}]"
plan "$SCRATCH/cbd.json" "[{\"address\":\"$A\",\"mode\":\"managed\",\"change\":{\"actions\":[\"create\",\"delete\"]}}]"
plan "$SCRATCH/forget.json" "[{\"address\":\"$A\",\"mode\":\"managed\",\"change\":{\"actions\":[\"forget\"]}}]"
rm -f stacks/local-security/import-*.tf
check "a pure import is allowed" test "$(rc_ "$SCRATCH/import.json" lon1)" -eq 0
check "an import that would update the live object is refused" test "$(rc_ "$SCRATCH/import-update.json" lon1)" -eq 2
check "a create during an import tranche is refused" test "$(rc_ "$SCRATCH/import-create.json" lon1)" -eq 2
check "creates and updates are allowed outside a tranche" test "$(rc_ "$SCRATCH/create-update.json" lon1)" -eq 0
check "a destroy is refused" test "$(rc_ "$SCRATCH/delete.json" lon1)" -eq 2
check "a replace is refused" test "$(rc_ "$SCRATCH/replace.json" lon1)" -eq 2
check "a create-before-destroy replace is refused" test "$(rc_ "$SCRATCH/cbd.json" lon1)" -eq 2
check "handing an object back (forget) is allowed" test "$(rc_ "$SCRATCH/forget.json" lon1)" -eq 0
printf '# approved in review\nlon1 local-security %s\n' "module.policies[\"p\"].nsxt_policy_security_policy_rule.this[\"r\"]" >allow-destroy.txt
check "a destroy approved in allow-destroy.txt is allowed" test "$(rc_ "$SCRATCH/delete.json" lon1)" -eq 0
check "the approval does not extend to another manager" test "$(rc_ "$SCRATCH/delete.json" nyc1)" -eq 2
out="$(python3 scripts/plan-guard.py --site lon1 --stack local-security "$SCRATCH/forget.json" 2>&1)"
check "an approval that matches nothing is reported as stale" grep -q "which this plan does not destroy" <<<"$out"
echo "lon1 local-security" >>allow-destroy.txt
check "a malformed approval line is an error" test "$(rc_ "$SCRATCH/delete.json" lon1)" -eq 1
rm -f allow-destroy.txt
out="$(python3 scripts/plan-guard.py --site lon1 --stack local-security "$SCRATCH/delete.json" 2>&1)"
check "a refusal prints the approval line to paste" grep -q "^  lon1 local-security module.policies" <<<"$out"
printf 'import {\n  to = a.b\n  id = "x"\n}\n' >stacks/local-security/import-lon1-t.tf
check "this manager's open tranche file makes the stack import-only" test "$(rc_ "$SCRATCH/create-update.json" lon1)" -eq 2
check "another manager's tranche file does not" test "$(rc_ "$SCRATCH/create-update.json" nyc1)" -eq 0
out="$(python3 scripts/plan-guard.py --site lon1 --stack local-security "$SCRATCH/import.json" 2>&1; python3 scripts/plan-guard.py --site lon1 --stack local-security <(plan /dev/stdout '[]') 2>&1)"
check "an applied tranche's leftover file is pointed out" grep -q "imports nothing new, so that tranche is applied" <<<"$out"
rm -f stacks/local-security/import-lon1-t.tf
check "input that is not a plan is an error" bash -c '! echo nope | python3 scripts/plan-guard.py --site lon1 --stack local-security >/dev/null 2>&1'
obs() { python3 scripts/plan-guard.py --site lon1 --stack local-security --observe "$1" >/dev/null 2>&1; echo $?; }
plan "$SCRATCH/noop.json" "[{\"address\":\"$A\",\"mode\":\"managed\",\"change\":{\"actions\":[\"no-op\"]}},{\"address\":\"data.x.y\",\"mode\":\"data\",\"change\":{\"actions\":[\"read\"]}}]"
check "observe (mirror mode): imports are allowed" test "$(obs "$SCRATCH/import.json")" -eq 0
check "observe: a plan with nothing to change is allowed" test "$(obs "$SCRATCH/noop.json")" -eq 0
check "observe: creates and updates are refused, even outside a tranche" test "$(obs "$SCRATCH/create-update.json")" -eq 2
check "observe: an update during an import is refused" test "$(obs "$SCRATCH/import-update.json")" -eq 2
check "observe: hand-backs (forget) are refused" test "$(obs "$SCRATCH/forget.json")" -eq 2
printf 'lon1 local-security %s\n' "module.policies[\"p\"].nsxt_policy_security_policy_rule.this[\"r\"]" >allow-destroy.txt
check "observe: a destroy is refused even when approved in allow-destroy.txt" test "$(obs "$SCRATCH/delete.json")" -eq 2
rm -f allow-destroy.txt
out="$(NSX_MODE=mirror python3 scripts/plan-guard.py --site lon1 --stack local-security --observe "$SCRATCH/create-update.json" 2>&1)"
check "observe: the refusal explains a manager changed since its last sync" grep -q "changed in the UI after the last sync" <<<"$out"

echo "tf.sh: one manager's state and plan never reach another"
mkdir -p "$SCRATCH/fake"
cat >"$SCRATCH/fake/terraform" <<'STUB'
#!/usr/bin/env bash
# Records what tf.sh asks of it; plays a plan that changes nothing.
echo "$*" >>"$FAKE_LOG"
case "$1" in
init) mkdir -p .terraform ;;
plan) : >tfplan ;;
show) [ "${2:-}" = -json ] && echo '{"format_version":"1.2","resource_changes":[]}' ;;
esac
exit 0
STUB
chmod +x "$SCRATCH/fake/terraform"
for s in lon1 nyc1; do printf 'path = "%s.tfstate"\n' "$s" >"envs/$s.backend.hcl"; done
export FAKE_LOG="$SCRATCH/fake.log"
tf() { env PATH="$SCRATCH/fake:$PATH" scripts/tf.sh "$@" 2>&1; }
: >"$FAKE_LOG"
tf plan local-security lon1 >/dev/null
tf plan local-security nyc1 >/dev/null
check "planning a second manager re-initialises for its own backend" grep -q "init .*envs/nyc1.backend.hcl" "$FAKE_LOG"
: >"$FAKE_LOG"
tf plan local-security nyc1 >/dev/null
check "the same manager again does not re-initialise" bash -c '! grep -q "^init" "$1"' _ "$FAKE_LOG"
check "the saved plan records its manager" test "$(cat stacks/local-security/tfplan.site)" = nyc1
out="$(APPROVE=yes tf apply local-security lon1)"
check "a plan made for one manager is refused for another" grep -q "was made for 'nyc1', not 'lon1'" <<<"$out"
check "...before anything is applied" bash -c '! grep -q "^apply" "$1"' _ "$FAKE_LOG"
rm -f stacks/local-security/tfplan.site
check "a plan with no record of its manager is refused" grep -q "was made for 'an unknown manager'" <<<"$(APPROVE=yes tf apply local-security nyc1)"
sed -i '/^  nyc1:$/a\    mode: mirror' inventory/managers.yaml
check "a manager in mode: mirror is refused the write credential, whatever the plan" grep -q "nyc1 is in mirror mode: only its state is updated, and only with the read-only credential" <<<"$(APPROVE=yes NSX_CRED_SCOPE=apply tf apply local-security nyc1)"
check "...and refused without a scope at all" grep -q "only with the read-only credential" <<<"$(APPROVE=yes tf apply local-security nyc1)"
out="$(APPROVE=yes NSX_MODE_LON1=managed tf apply local-security lon1)"
check "a leftover NSX_MODE_ variable stops tf.sh, and nothing is applied" bash -c 'grep -q "comes from inventory/managers.yaml only" <<<"$1" && grep -q "cannot read manager .lon1." <<<"$1" && ! grep -q "Apply complete" <<<"$1"' _ "$out"
sed -i '/^  lon1:$/a\    mode: sideways' inventory/managers.yaml
check "an unknown mode in the inventory is an error, and nothing is applied" grep -q "mode 'sideways' in inventory/managers.yaml must be one of: managed, mirror" <<<"$(APPROVE=yes tf apply local-security lon1)"
sed -i '/^    mode: sideways$/d' inventory/managers.yaml
sed -i '/^    mode: mirror$/d' inventory/managers.yaml
tf plan local-security nyc1 >/dev/null
# The test tree is on the placeholder local backend, which tf.sh only applies to
# when told it is a lab.
out="$(APPROVE=yes ALLOW_LOCAL_STATE=1 tf apply local-security nyc1)"
check "the right plan for the right manager applies" grep -q "^apply" "$FAKE_LOG"
check "the plan and its record are removed after apply" bash -c '! test -e stacks/local-security/tfplan && ! test -e stacks/local-security/tfplan.site'
check "the child pipeline carries the record with the plan" grep -q "tfplan.site" <<<"$(python3 scripts/gitlab-child-pipeline.py)"

echo "hand-back"
A2='module.policies["legacy-app"].nsxt_policy_security_policy_rule.this["web-to-db"]'
python3 scripts/hand-back.py --stack local-security --address "$A2" >/dev/null 2>&1
H="$(cat stacks/local-security/handback-legacy_app_web_to_db.tf 2>/dev/null)"
check "it moves the instance to a stand-alone address" grep -qF "from = $A2" <<<"$H"
check "...and forgets it without destroying" bash -c 'grep -q "nsxt_policy_security_policy_rule.handback_legacy_app_web_to_db" <<<"$1" && grep -q "destroy = false" <<<"$1"' _ "$H"
check "it will not overwrite an existing hand-back" bash -c '! python3 scripts/hand-back.py --stack local-security --address "$1" >/dev/null 2>&1' _ "$A2"
check "a non-NSX address is refused" bash -c '! python3 scripts/hand-back.py --stack local-security --address "random_id.x" >/dev/null 2>&1'
check "an unknown stack is refused" bash -c '! python3 scripts/hand-back.py --stack nope --address "$1" >/dev/null 2>&1' _ "$A2"

echo "validator"
mkdir -p "$SCRATCH/v" && cp -r data inventory scripts "$SCRATCH/v/" 2>/dev/null
cat >"$SCRATCH/v/data/services/extra.yaml" <<'YAML'
custom:
  Everywhere:
    display_name: Everywhere
    owner: lm
    l4_port_set:
      - protocol: TCP
        destination_ports: ["1"]
YAML
check "a site-local service without sites is an error" grep -q "lists no sites, so it is created on EVERY" <<<"$(cd "$SCRATCH/v" && python3 scripts/validate-data.py 2>&1)"
sed -i 's#rules:#rules:#' "$SCRATCH/v/data/policies/legacy-app.yaml"
check "context profiles may be referenced by path" bash -c '! (cd "$1" && python3 scripts/validate-data.py 2>&1) | grep -q "context-profiles"' _ "$SCRATCH/v"
sed -i 's#scope: \[App-All\]#scope: [/infra/domains/default/groups/App-All]#' "$SCRATCH/v/data/policies/legacy-app.yaml"
check "any other raw path is still an error" grep -q "raw policy path" <<<"$(cd "$SCRATCH/v" && python3 scripts/validate-data.py 2>&1)"

echo "federation: a Global Manager and a Local Manager, side by side"
F="$SCRATCH/fed"
generate "$F" --no-examples
cd "$F" || exit 1
mkdir -p reports
printf 'managers:\n  gm1:\n    role: gm\n    host: gm.example.net\n    site: global\n    vcf_instance: v\n    vault_path: secret/gm1\n    tier: prod\n  lon1:\n    role: lm\n    host: lon1.example.net\n    site: lon1\n    vcf_instance: v\n    vault_path: secret/lon1\n    tier: prod\n' >inventory/managers.yaml
python3 - <<'PY'
import json
GD = "/global-infra/domains/default"; LD = "/infra/domains/default"
cond = lambda v: [{"resource_type": "Condition", "key": "Tag", "member_type": "VirtualMachine", "operator": "EQUALS", "value": v}]
def grp(base, i, expr): return {"id": i, "path": f"{base}/groups/{i}", "display_name": i, "expression": expr}
def rule(base, p, i, src, dst, svc, seq):
    return {"id": i, "path": f"{base}/security-policies/{p}/rules/{i}", "display_name": i, "sequence_number": seq, "action": "ALLOW",
            "direction": "IN_OUT", "ip_protocol": "IPV4_IPV6", "logged": True, "source_groups": src, "destination_groups": dst,
            "services": svc, "scope": ["ANY"], "profiles": ["ANY"]}
def pol(base, i, rules, scope): return {"id": i, "path": f"{base}/security-policies/{i}", "display_name": i, "category": "Application",
                                        "sequence_number": 10, "stateful": True, "scope": scope, "rules": rules}
https_g = {"id": "HTTPS", "path": "/global-infra/services/HTTPS", "display_name": "HTTPS", "_system_owned": True, "service_entries": []}
gsvc = {"id": "G-Svc", "path": "/global-infra/services/G-Svc", "display_name": "G-Svc",
        "service_entries": [{"resource_type": "L4PortSetServiceEntry", "display_name": "t9443", "l4_protocol": "TCP", "destination_ports": ["9443"]}]}
gm = {"domain": "default",
      "groups": [grp(GD, "G-Web", cond("tier|web")), grp(GD, "Shared", cond("app|shared-gm"))],
      "services": [https_g, gsvc],
      "policies": [pol(GD, "g-pol", [rule(GD, "g-pol", "g1", [f"{GD}/groups/G-Web"], [f"{GD}/groups/Shared"], ["/global-infra/services/HTTPS"], 100)], [f"{GD}/groups/G-Web"])]}
json.dump(gm, open("reports/gm1.json", "w"))
lm = {"domain": "default",
      "groups": [grp(LD, "L-App", cond("app|l")), grp(LD, "Shared", cond("app|shared-lm")),
                 grp(LD, "Nest-G", [{"resource_type": "PathExpression", "paths": [f"{GD}/groups/G-Web"]}]),
                 grp(GD, "G-Web", cond("tier|web"))],            # a global object, listed by the LM
      "services": [{"id": "HTTPS", "path": "/infra/services/HTTPS", "display_name": "HTTPS", "_system_owned": True, "service_entries": []}],
      "policies": [pol(LD, "l-pol", [
          rule(LD, "l-pol", "r1", [f"{GD}/groups/G-Web"], [f"{LD}/groups/L-App"], ["/global-infra/services/G-Svc", "/infra/services/HTTPS"], 100),
          rule(LD, "l-pol", "r2", [f"{LD}/groups/Shared"], [f"{LD}/groups/L-App"], ["ANY"], 200),
          rule(LD, "l-pol", "r3", [f"{GD}/groups/Unknown-G"], [f"{LD}/groups/L-App"], ["ANY"], 300),
      ], [f"{LD}/groups/L-App"])]}
json.dump(lm, open("reports/lon1.json", "w"))
PY
mir() { python3 scripts/import-estate.py --site "$1" --from-dump "reports/$1.json" --mirror 2>&1; }
ids_twice() { python3 - <<'PY'
import sys, yaml, glob, collections
seen = collections.Counter()
for f in glob.glob("data/groups/*.yaml"): seen.update((yaml.safe_load(open(f)) or {}).get("groups", {}).keys())
for f in glob.glob("data/services/*.yaml"): seen.update((yaml.safe_load(open(f)) or {}).get("custom", {}).keys())
dup = [k for k, n in seen.items() if n > 1]
print(" ".join(dup)); sys.exit(1 if dup else 0)
PY
}
out_gm="$(mir gm1)"
out="$(mir lon1)"
LG="$(cat data/groups/imported-lon1-mirror.yaml)"
LP="$(cat data/policies/l-pol.yaml)"
check "the GM's objects are the GM's: owner gm, read from the global tree" bash -c 'grep -q "owner: gm" data/groups/imported-gm1-mirror.yaml && grep -q "^  G-Web:" data/groups/imported-gm1-mirror.yaml'
check "...all of them taken, nothing left out" bash -c '! grep -q "NOT ADOPTED" <<<"$1" && grep -q "2 group(s), 1 policy/policies, 1 rule(s), 1 custom service(s)" <<<"$1"' _ "$out_gm"
check "a global object an LM lists is not adopted from the LM" bash -c '! grep -q "^  G-Web:" <<<"$1" && grep -q "G-Web: belongs to the Global Manager" <<<"$2"' _ "$LG" "$out"
check "no group or service id is declared twice" ids_twice
check "an LM rule using a global group and service names them; the LM stack resolves them" bash -c 'python3 -c "import yaml,sys;r=yaml.safe_load(sys.stdin)[\"rules\"][\"r1\"];sys.exit(0 if r[\"source_groups\"]==[\"G-Web\"] and r[\"services\"]==[\"G-Svc\",\"HTTPS\"] else 1)" <<<"$1"' _ "$LP"
check "an LM group with the id of a GM group is not adopted, and says why" bash -c '! grep -q "^  Shared:" <<<"$1" && grep -q "group Shared: its id is also the Global Manager.s group" <<<"$2"' _ "$LG" "$out"
check "...nor the rule using it, which would bind to the GM's group" bash -c 'grep -q "rule l-pol/r2: uses Shared" <<<"$1" && ! grep -q "^  r2:" <<<"$2"' _ "$out" "$LP"
check "an LM group nesting a global group is not adopted" grep -q "group Nest-G: nests the global group G-Web" <<<"$out"
check "a rule using a global group data/ does not declare stays in the UI, and says why" bash -c 'grep -q "rule l-pol/r3: uses Unknown-G (uses the global group Unknown-G, which data/ does not declare" <<<"$1" && ! grep -q "^  r3:" <<<"$2"' _ "$out" "$LP"
check "a rule and a policy applied to ANY are written as ANY, not as a missing Apply To" bash -c 'python3 -c "import yaml,sys;d=yaml.safe_load(open(\"data/policies/g-pol.yaml\"));sys.exit(0 if d[\"rules\"][\"g1\"][\"scope\"]==[\"ANY\"] else 1)"' 
check "no raw policy path is written anywhere" bash -c '! grep -rn "/global-infra/\|\"/infra/\| /infra/" data/groups data/policies data/services'
check "the copy validates, HTTPS named by both managers included" python3 scripts/validate-data.py
check "the LM stack resolves GM-owned names to their global paths, and never manages them" bash -c 'grep -q "global_group_paths" stacks/local-security/main.tf && grep -q "/global-infra/domains/\${try(g.domain, \"default\")}/groups/\${try(g.nsx_id, k)}" stacks/local-security/main.tf && grep -q "if try(g.owner, \"lm\") == \"lm\"" stacks/local-security/main.tf'
before="$(cat data/groups/*.yaml data/services/*.yaml data/policies/*.yaml stacks/*/import-*.tf | sha256sum)"
mir gm1 >/dev/null; mir lon1 >/dev/null
check "syncing both again changes nothing" test "$(cat data/groups/*.yaml data/services/*.yaml data/policies/*.yaml stacks/*/import-*.tf | sha256sum)" = "$before"

# The other order: the Local Manager first.
rm -rf data/groups data/services data/policies data/.import-manifest.json stacks/*/import-*.tf
mkdir -p data/groups data/services data/policies
out="$(mir lon1)"
check "LM first: its rule using the not-yet-copied global group waits in the UI" grep -q "rule l-pol/r1: uses G-Web (uses the global group G-Web, which data/ does not declare" <<<"$out"
out="$(mir gm1)"
check "...the GM then leaves its Shared to the LM that claimed the id, and says so" grep -q "group Shared: its id is also another manager.s group" <<<"$out"
check "...and a policy left with no adoptable rule stays whole in the UI" bash -c 'grep -q "policy g-pol: none of its 1 rule(s) can be adopted" <<<"$1" && ! test -f data/policies/g-pol.yaml' _ "$out"
mir lon1 >/dev/null
check "...and the next LM sync takes the rule: both orders converge" bash -c 'python3 -c "import yaml,sys;sys.exit(0 if \"r1\" in yaml.safe_load(open(\"data/policies/l-pol.yaml\"))[\"rules\"] else 1)"'
check "...still with no id declared twice" ids_twice
check "...and valid" python3 scripts/validate-data.py
check "GM domain: global objects are read from domain default unless the inventory says otherwise" bash -c 'grep -q "or \"default\"$" scripts/import-estate.py'

echo "estate shapes: VM members, IP addresses in rules, Global Manager location domains"
rm -rf data/groups data/services data/policies data/.import-manifest.json stacks/*/import-*.tf
mkdir -p data/groups data/services data/policies
python3 - <<'PY'
import json
GD = "/global-infra/domains/default"; WD = "/global-infra/domains/WL-Mum"; LD = "/infra/domains/default"
cond = lambda v: [{"resource_type": "Condition", "key": "Tag", "member_type": "VirtualMachine", "operator": "EQUALS", "value": v}]
def grp(base, i, expr): return {"id": i, "path": f"{base}/groups/{i}", "display_name": i, "expression": expr}
def rule(base, p, i, src, dst, seq, scope=("ANY",)):
    return {"id": i, "path": f"{base}/security-policies/{p}/rules/{i}", "display_name": i, "sequence_number": seq, "action": "ALLOW",
            "direction": "IN_OUT", "ip_protocol": "IPV4_IPV6", "logged": True, "source_groups": src, "destination_groups": dst,
            "services": ["ANY"], "scope": list(scope), "profiles": ["ANY"]}
def pol(base, i, rules): return {"id": i, "path": f"{base}/security-policies/{i}", "display_name": i, "category": "Application",
                                 "sequence_number": 10, "stateful": True, "scope": ["ANY"], "rules": rules}
vms = [{"resource_type": "ExternalIDExpression", "member_type": "VirtualMachine",
        "external_ids": ["502e6f1a-0000-0000-0000-000000000001", "502e6f1a-0000-0000-0000-000000000002"]}]
gm = {"domain": "default", "domains": ["default", "WL-Mum"],
      "groups": [grp(GD, "VM-Jump", vms), grp(GD, "Clash", cond("app|a")),
                 grp(WD, "M-App", cond("app|mum")), grp(WD, "Clash", cond("app|b"))],
      "services": [],
      "policies": [pol(GD, "g-pol", [
                       rule(GD, "g-pol", "uses-location-group", [f"{GD}/groups/VM-Jump"], [f"{WD}/groups/M-App"], 100),
                       rule(GD, "g-pol", "ips", ["172.19.20.57", "10.1.0.0/16"], ["172.17.9.10-172.17.9.20"], 200),
                       rule(GD, "g-pol", "uses-clash", [f"{WD}/groups/Clash"], ["ANY"], 300),
                       dict(rule(GD, "g-pol", "inline-ports", ["ANY"], [f"{GD}/groups/Clash"], 400), services=["ANY"],
                            service_entries=[{"resource_type": "L4PortSetServiceEntry", "display_name": "t8080", "l4_protocol": "TCP",
                                              "destination_ports": ["8080"], "source_ports": []}])]),
                   pol(WD, "mum-pol", [rule(WD, "mum-pol", "m1", [f"{WD}/groups/M-App"], ["ANY"], 100)]),
                   # The same policy id in two domains, and a policy NSX holds empty.
                   pol(GD, "CSS", [rule(GD, "CSS", "c1", [f"{GD}/groups/Clash"], ["ANY"], 100)]),
                   pol(WD, "CSS", [rule(WD, "CSS", "c1", [f"{WD}/groups/Clash"], ["ANY"], 100)]),
                   pol(GD, "placeholder", [])]}
json.dump(gm, open("reports/gm1.json", "w"))
lm = {"domain": "default",
      "groups": [grp(LD, "L-App", cond("app|l"))], "services": [],
      "policies": [pol(LD, "l-pol", [rule(LD, "l-pol", "r1", [f"{WD}/groups/M-App"], [f"{LD}/groups/L-App"], 100)])]}
json.dump(lm, open("reports/lon1.json", "w"))
PY
out_gm="$(mir gm1)"
out="$(mir lon1)"
G="$(cat data/groups/imported-gm1-mirror.yaml)"
check "a group of VMs picked one by one is adopted, as external ids" bash -c 'python3 -c "import yaml,sys;g=yaml.safe_load(sys.stdin)[\"groups\"][\"VM-Jump\"];c=g[\"criteria\"][0];sys.exit(0 if c[\"member_type\"]==\"VirtualMachine\" and len(c[\"external_ids\"])==2 and g[\"why_static\"] else 1)" <<<"$1"' _ "$G"
check "a rule with IP addresses, a CIDR and a range is adopted, with them as written" bash -c 'python3 -c "import yaml,sys;r=yaml.safe_load(open(\"data/policies/g-pol.yaml\"))[\"rules\"][\"ips\"];sys.exit(0 if r[\"source_groups\"]==[\"172.19.20.57\",\"10.1.0.0/16\"] and r[\"destination_groups\"]==[\"172.17.9.10-172.17.9.20\"] else 1)"'
check "a location domain's group is adopted as <id>@<domain>, with its domain and its NSX id" bash -c 'python3 -c "import yaml,sys;g=yaml.safe_load(sys.stdin)[\"groups\"][\"M-App@WL-Mum\"];sys.exit(0 if g[\"domain\"]==\"WL-Mum\" and g[\"nsx_id\"]==\"M-App\" else 1)" <<<"$1"' _ "$G"
check "...and a global rule using it is adopted, naming it by that key" bash -c 'python3 -c "import yaml,sys;r=yaml.safe_load(open(\"data/policies/g-pol.yaml\"))[\"rules\"][\"uses-location-group\"];sys.exit(0 if r[\"destination_groups\"]==[\"M-App@WL-Mum\"] else 1)"'
check "a location domain's policy is adopted in its domain, in <id>@<domain>.yaml, with its NSX id" bash -c 'python3 -c "import yaml,sys;p=yaml.safe_load(open(\"data/policies/mum-pol@WL-Mum.yaml\"))[\"policy\"];sys.exit(0 if p[\"domain\"]==\"WL-Mum\" and p[\"id\"]==\"mum-pol\" else 1)"'
check "the same group id in two domains: both adopted, each under its own key" bash -c 'python3 -c "import yaml,sys;g=yaml.safe_load(sys.stdin)[\"groups\"];sys.exit(0 if \"domain\" not in g[\"Clash\"] and g[\"Clash@WL-Mum\"][\"nsx_id\"]==\"Clash\" else 1)" <<<"$1" && ! grep -q "NOT ADOPTED" <<<"$2"' _ "$G" "$out_gm"
check "...and the rule using the other one is adopted, naming that one" bash -c 'python3 -c "import yaml,sys;r=yaml.safe_load(open(\"data/policies/g-pol.yaml\"))[\"rules\"][\"uses-clash\"];sys.exit(0 if r[\"source_groups\"]==[\"Clash@WL-Mum\"] else 1)"'
check "the same policy id in two domains: both adopted, one file each" bash -c 'python3 -c "import yaml,sys;a=yaml.safe_load(open(\"data/policies/CSS.yaml\"));b=yaml.safe_load(open(\"data/policies/CSS@WL-Mum.yaml\"));sys.exit(0 if a[\"policy\"][\"id\"]==b[\"policy\"][\"id\"]==\"CSS\" and b[\"policy\"][\"domain\"]==\"WL-Mum\" and a[\"rules\"][\"c1\"][\"source_groups\"]==[\"Clash\"] and b[\"rules\"][\"c1\"][\"source_groups\"]==[\"Clash@WL-Mum\"] else 1)"'
check "a policy NSX holds empty is adopted, empty" bash -c 'python3 -c "import yaml,sys;d=yaml.safe_load(open(\"data/policies/placeholder.yaml\"));sys.exit(0 if not d.get(\"rules\") else 1)"'
check "a rule with ports written in it is adopted, with them" bash -c 'python3 -c "import yaml,sys;r=yaml.safe_load(open(\"data/policies/g-pol.yaml\"))[\"rules\"][\"inline-ports\"];e=r[\"service_entries\"][\"l4_port_set\"][0];sys.exit(0 if e[\"protocol\"]==\"TCP\" and e[\"destination_ports\"]==[\"8080\"] else 1)"'
check "a Local Manager rule using a location domain's global group is adopted" bash -c 'python3 -c "import yaml,sys;r=yaml.safe_load(open(\"data/policies/l-pol.yaml\"))[\"rules\"][\"r1\"];sys.exit(0 if r[\"source_groups\"]==[\"M-App@WL-Mum\"] else 1)"'
check "...and the Local Manager stack finds it by its NSX id, in its domain" bash -c 'grep -q "groups/\${try(g.nsx_id, k)}" stacks/local-security/main.tf'
check "import ids keep each object's own domain and NSX id" bash -c 'grep -q "\"Clash@WL-Mum\" *= \"/global-infra/domains/WL-Mum/groups/Clash\"" stacks/global-security/import-gm1-mirror.tf && grep -q "/global-infra/domains/WL-Mum/security-policies/mum-pol\"" stacks/global-security/import-gm1-mirror.tf'
check "it all validates" python3 scripts/validate-data.py
check "the group module builds external ids" grep -q "external_id_expression" modules/group/main.tf
check "the policy module takes an address in a rule without looking it up as a group" bash -c 'grep -q "ip_literal" modules/dfw-policy/main.tf'
cp data/policies/g-pol.yaml "$SCRATCH/g-pol.yaml"
cp data/groups/imported-gm1-mirror.yaml "$SCRATCH/gm1-groups.yaml"
python3 - <<'PY'
import importlib.util, yaml
spec = importlib.util.spec_from_file_location("ie", "scripts/import-estate.py"); ie = importlib.util.module_from_spec(spec); spec.loader.exec_module(ie)
# Written as the repository writes YAML, so any of its readers takes it.
d = yaml.safe_load(open("data/policies/g-pol.yaml")); d["rules"]["ips"]["scope"] = ["10.9.9.9"]
open("data/policies/g-pol.yaml", "w").write(ie.to_yaml(d))
d = yaml.safe_load(open("data/groups/imported-gm1-mirror.yaml")); del d["groups"]["VM-Jump"]["criteria"][0]["member_type"]
open("data/groups/imported-gm1-mirror.yaml", "w").write(ie.to_yaml(d))
PY
out="$(python3 scripts/validate-data.py 2>&1)"
check "an address in an Apply To is refused, and says where addresses are allowed" grep -q "not in its Apply To" <<<"$out"
check "external ids without a member_type are refused" grep -q "external_ids and member_type go together" <<<"$out"
cp "$SCRATCH/g-pol.yaml" data/policies/g-pol.yaml
cp "$SCRATCH/gm1-groups.yaml" data/groups/imported-gm1-mirror.yaml
python3 - <<'PY'
import json
GD = "/global-infra/domains/default"
vm = [{"resource_type": "ExternalIDExpression", "member_type": "VirtualMachine", "external_ids": ["502e6f1a-0000-0000-0000-000000000009"]}]
ids = ["_h-cis-np-ansi02", "_Exchange-GW_VM's", "WIN11 IC SI H 2025"]
groups = [{"id": i, "path": f"{GD}/groups/{i}", "display_name": i, "expression": vm} for i in ids]
rules = [{"id": f"r {n}", "path": f"{GD}/security-policies/_My Policy/rules/r {n}", "display_name": "r", "sequence_number": 100 * (n + 1),
          "action": "ALLOW", "direction": "IN_OUT", "logged": True, "source_groups": [g["path"]], "destination_groups": ["ANY"],
          "services": ["ANY"], "scope": ["ANY"], "profiles": ["ANY"]} for n, g in enumerate(groups)]
d = json.load(open("reports/gm1.json"))
d["groups"] += groups
d["policies"].append({"id": "_My Policy", "path": f"{GD}/security-policies/_My Policy", "display_name": "My Policy",
                      "category": "Application", "sequence_number": 50, "scope": ["ANY"], "rules": rules})
json.dump(d, open("reports/gm1.json", "w"))
PY
out="$(mir gm1)"
check "ids made in the UI ('_h-…', apostrophes, spaces) are adopted verbatim" bash -c '! grep -q "NOT ADOPTED  group _\|NOT ADOPTED  group WIN11" <<<"$1" && test -f "data/policies/_My Policy.yaml" && grep -q "_Exchange-GW_VM" data/groups/imported-gm1-mirror.yaml' _ "$out"
python3 - <<'PY'
import json
GD = "/global-infra/domains/default"
c = lambda v: [{"resource_type": "Condition", "key": "Tag", "member_type": "VirtualMachine", "operator": "EQUALS", "value": v}]
odd = ["Azure-AD-IP's", "100", "-lead", "a,b [c]", 'say "hi"', "back\\slash", "#hash", "@at", "x: y"]
groups = [{"id": i, "path": f"{GD}/groups/{i}", "display_name": i, "description": "line one\nline 'two'\ttab", "expression": c("app|x")} for i in odd]
svc = [{"id": "gm_UDP_49152–65535", "path": "/global-infra/services/gm_UDP_49152–65535", "display_name": "gm UDP 49152–65535",
        "service_entries": [{"resource_type": "L4PortSetServiceEntry", "l4_protocol": "UDP", "destination_ports": ["49152-65535"]}]}]
def pol(i):
    return {"id": i, "path": f"{GD}/security-policies/{i}", "display_name": "CSS", "category": "Application", "sequence_number": 7,
            "scope": ["ANY"], "rules": [{"id": "r1", "path": f"{GD}/security-policies/{i}/rules/r1", "display_name": "r1", "sequence_number": 470,
                                         "action": "ALLOW", "direction": "IN_OUT", "logged": True, "source_groups": [g["path"] for g in groups],
                                         "destination_groups": ["ANY"], "services": [svc[0]["path"]], "scope": ["ANY"], "profiles": ["ANY"]}]}
d = json.load(open("reports/gm1.json"))
d["groups"] += groups; d["services"] += svc; d["policies"] += [pol("CSS"), pol("CSS-LbTAAIz-d")]
json.dump(d, open("reports/gm1.json", "w"))
PY
out="$(mir gm1)"
check "names NSX allows (quotes, commas, a leading '-', a number, ': ') are written as YAML both parsers read the same" python3 - <<'PY'
import glob, os, sys, yaml
sys.path.insert(0, "scripts")
os.environ["NSX_YAML_FALLBACK"] = "1"
from yamlcompat import load_yaml
bad = [f for f in glob.glob("data/*/*.yaml") if yaml.safe_load(open(f)) != load_yaml(open(f).read())]
print(bad, file=sys.stderr)
sys.exit(1 if bad else 0)
PY
check "...the odd names reach the copy intact" python3 -c "import yaml,sys;g=yaml.safe_load(open('data/groups/imported-gm1-mirror.yaml'))['groups'];sys.exit(0 if {\"Azure-AD-IP's\",'100','-lead','a,b [c]','say \"hi\"','back\\\\slash','#hash','@at','x: y'} <= set(g) and g['100']['description']=='line one\nline \'two\'\ttab' else 1)"
check "two policies NSX holds under one display name are both taken, and validate without PyYAML too" bash -c 'test -f data/policies/CSS.yaml && test -f data/policies/CSS-LbTAAIz-d.yaml && ! NSX_YAML_FALLBACK=1 python3 scripts/validate-data.py 2>&1 | grep -q "^ERROR"'
check "imported rules' sequence numbers are taken as they are, without a warning each" bash -c '! python3 scripts/validate-data.py 2>&1 | grep -q "CSS.yaml.*not a multiple of 100"'
check "...and validate: an adopted object keeps its own id" bash -c '! python3 scripts/validate-data.py 2>&1 | grep -q "^ERROR"'
printf 'groups:\n  _new one:\n    display_name: x\n    owner: gm\n    criteria:\n      - conditions:\n          - {key: Tag, member_type: VirtualMachine, operator: EQUALS, value: "app|x"}\n' >data/groups/authored.yaml
check "a new object written here is still held to letters, digits, '.', '_' and '-'" bash -c 'python3 scripts/validate-data.py 2>&1 | grep -q "a new object.s id is letters, digits"'
rm data/groups/authored.yaml
python3 - <<'PY'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("ie", "scripts/import-estate.py"); ie = importlib.util.module_from_spec(spec); spec.loader.exec_module(ie)
calls = []
def fake(host, path, *a):
    calls.append(path)
    if path.endswith("/global-infra/domains"): return {"results": [{"id": "default"}, {"id": "WL-Mum"}]}
    if path.endswith("/groups"): return {"results": [{"id": "g", "path": path + "/g"}]}
    return {"results": []}
ie.api_get = fake
sys.stderr = open("/dev/null", "w")
e = ie.fetch_estate("h", "u", "p", ie.GM_BASE, "default", False)
ok = e["domains"] == ["default", "WL-Mum"] and len(e["groups"]) == 2 and any("/domains/WL-Mum/security-policies" in c for c in calls)
calls.clear()
e = ie.fetch_estate("h", "u", "p", ie.LM_BASE, "default", False)
ok = ok and e["domains"] == ["default"] and not any(c.endswith("/domains") for c in calls)
sys.exit(0 if ok else 1)
PY
check "a Global Manager is read in every domain, its own first; a Local Manager in default only" test $? -eq 0
cd "$T" || exit 1

finish brownfield
