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
    g("Mac", [{"resource_type": "MACAddressExpression", "mac_addresses": ["00:50:56:aa:bb:cc"]}]),
    g("Nests-Mac", [{"resource_type": "PathExpression", "paths": [f"{D}/groups/Mac"]}]),
    g("Other", [cond("app|other")]),
]
services = [
    {"id": "App-8443", "path": f"{SV}/App-8443", "display_name": "App 8443",
     "service_entries": [{"resource_type": "L4PortSetServiceEntry", "display_name": "TCP-8443", "l4_protocol": "TCP", "destination_ports": ["8443"]}]},
    {"id": "HTTPS", "path": f"{SV}/HTTPS", "display_name": "HTTPS", "_system_owned": True, "service_entries": []},
    {"id": "GRE", "path": f"{SV}/GRE", "display_name": "GRE", "service_entries": [{"resource_type": "IPProtocolServiceEntry", "protocol_number": 47}]},
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
check "a MAC-based group is not adopted, and says why" grep -q "group Mac: membership by MACAddressExpression" <<<"$out"
check "a group nesting it is not adopted" grep -q "group Nests-Mac: nests Mac" <<<"$out"
check "a service with other entry types is not adopted" grep -q "service GRE: service entries of type IPProtocolServiceEntry" <<<"$out"
check "a rule with inline service entries stays in the UI" grep -q "rule legacy-app/inline: inline service entries" <<<"$out"
check "rules using unadoptable objects stay in the UI" bash -c 'grep -q "rule legacy-app/printers: uses Nests-Mac" <<<"$1" && grep -q "rule legacy-app/gre: uses GRE" <<<"$1"' _ "$out"
check "the rest of the policy is still adopted" bash -c 'grep -q "^  web-to-db:" <<<"$1" && grep -q "^  jump-https:" <<<"$1" && ! grep -q "^  inline:" <<<"$1"' _ "$P"
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
d["groups"].append({"id": "New-G", "path": f"{D}/groups/New-G", "display_name": "New-G",
                    "expression": [{"resource_type": "IPAddressExpression", "ip_addresses": ["10.9.9.9"]}]})
fresh = next(p for p in d["policies"] if p["id"] == "fresh-app")
fresh["rules"][0]["action"] = "DROP"
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
check "a new merge request lists the changes" python3 -c "import json,sys;l=[json.loads(x) for x in open(sys.argv[1])];p=[x for x in l if x['method']=='POST'];d=p[-1]['body']['description'];sys.exit(0 if len(p)==2 and '| added | \`data/policies/new-app.yaml\` |' in d and '| changed | \`data/policies/fresh-app.yaml\` |' in d else 1)" "$SCRATCH/gl.log"
check "MIRROR_AUTO_MERGE=1 sets it to merge when its pipeline passes, retrying until GitLab accepts" bash -c 'grep -q "set to merge when its pipeline passes" <<<"$1" && [ "$(grep -c "/merge_requests/2/merge" "$2")" = 2 ]' _ "$out" "$SCRATCH/gl.log"
check "the mirrored data passes validation" python3 scripts/validate-data.py
merge_mirror

# ...and later delete them again.
python3 - <<'PY'
import json
d = json.load(open("reports/lon1-raw.json"))
d["groups"] = [g for g in d["groups"] if g["id"] != "New-G"]
d["policies"] = [p for p in d["policies"] if p["id"] != "new-app"]
json.dump(d, open("reports/lon1-raw.json", "w"))
PY
out="$(mirror)"
files="$(remote_files)"
check "a policy and a group deleted in the UI are deleted from the repository" bash -c 'grep -q "^D	data/policies/new-app.yaml" <<<"$1" && grep -q "^D	data/groups/imported-lon1-mirror.yaml" <<<"$1"' _ "$files"
check "...and from the import blocks" bash -c '! git -C "$1" show mirror/lon1:stacks/local-security/import-lon1-mirror.tf | grep -q "New-G\|new-app"' _ "$SCRATCH/remote.git"
check "...and from the manifest" bash -c '! git -C "$1" show mirror/lon1:data/.import-manifest.json | grep -q new-app' _ "$SCRATCH/remote.git"

out="$(mirror MIRROR_SITE=nyc1)"
rc=$?
check "a manager in mode: managed is refused, and the job fails" bash -c '[ "$2" -ne 0 ] && grep -q "nyc1 is in mode: managed" <<<"$1" && ! git -C "$3" rev-parse -q --verify refs/heads/mirror/nyc1' _ "$out" "$rc" "$SCRATCH/remote.git"
out="$(mirror MIRROR_SITE=all)"
check "MIRROR_SITE=all takes every manager in mode: mirror, and only those" bash -c 'grep -q "=== lon1" <<<"$1" && ! grep -q "=== nyc1" <<<"$1" && ! grep -q "=== gm1" <<<"$1"' _ "$out"
check "without MIRROR_SITE it refuses" grep -q "MIRROR_SITE is not set" <<<"$(mirror MIRROR_SITE=)"
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
check "NSX_MODE_<SITE> puts a manager in mirror mode without a commit" grep -q "lon1 is in mirror mode" <<<"$(APPROVE=yes NSX_MODE_LON1=mirror tf apply local-security lon1)"
check "...and an unknown value is an error naming the variable" grep -q "NSX_MODE_LON1 must be one of: managed, mirror" <<<"$(APPROVE=yes NSX_MODE_LON1=observe tf apply local-security lon1)"
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

finish brownfield
