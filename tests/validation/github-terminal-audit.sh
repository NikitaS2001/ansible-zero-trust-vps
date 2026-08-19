#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
umask 077

readonly max_pages=100
readonly required_one='security / lint-and-scan'
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)
validation_dir=${GITHUB_AUDIT_VALIDATION_DIR:-"$root/tests/validation"}
repo='' pr='' tested_sha='' base_sha='' attempt_dir='' tmp='' pages=0
threads_query="query(\$owner:String!,\$name:String!,\$number:Int!,\$cursor:String){repository(owner:\$owner,name:\$name){pullRequest(number:\$number){reviewThreads(first:100,after:\$cursor){nodes{isResolved} pageInfo{hasNextPage endCursor}}}}}"
reviews_query="query(\$owner:String!,\$name:String!,\$number:Int!,\$cursor:String){repository(owner:\$owner,name:\$name){pullRequest(number:\$number){reviews(first:100,after:\$cursor){nodes{state submittedAt author{login}} pageInfo{hasNextPage endCursor}}}}}"
checks_query="query(\$owner:String!,\$name:String!,\$number:Int!,\$cursor:String){repository(owner:\$owner,name:\$name){pullRequest(number:\$number){commits(last:1){nodes{commit{oid statusCheckRollup{contexts(first:100,after:\$cursor){nodes{__typename ... on CheckRun{name status conclusion workflowRun{workflow{name}}} ... on StatusContext{context state}} pageInfo{hasNextPage endCursor}}}}}}}}}"

reject() { printf '%s\n' "AUDIT_REJECT:$1" >&2; exit 1; }
cleanup() { local rc=$?; [[ -z "$tmp" ]] || find "$tmp" -depth -delete; exit "$rc"; }
trap cleanup EXIT
usage() { printf '%s\n' 'usage: github-terminal-audit.sh --repo OWNER/NAME --pr NUMBER --tested-sha SHA --base-sha SHA --attempt-dir DIR'; }
need() { command -v "$1" >/dev/null 2>&1 || reject "missing-$1"; }

receipt() {
  local file=$1 exempt=${2:-no}
  [[ -f "$file" && ! -L "$file" ]] || reject receipt-type
  [[ $(stat -c %a -- "$file") == 600 && $(stat -c %h -- "$file") == 1 ]] || reject receipt-permissions
  [[ "$exempt" == yes ]] || grep -Fqx "tested_sha=$tested_sha" "$file" >/dev/null 2>&1 || reject receipt-sha
}

reject_secret_evidence() {
  if rg -uuu -P -- '-----BEGIN (?:OPENSSH |RSA |EC |DSA )?PRIVATE KEY-----|AGE-SECRET-KEY-|(?:^|\s)(?:PrivateKey|PresharedKey)\s*=|(?:^|\s)(?:INIT_PASSWORD|ZERO_TRUST_[A-Z0-9_]*PASSWORD)\s*=\s*(?!<redacted>$)' "$1" >/dev/null 2>&1; then
    reject secret-evidence
  fi
}

receipts() {
  local name original entries
  [[ -f "$validation_dir/evidence-manifest.txt" && -f "$validation_dir/final-evidence-manifest.txt" ]] || reject receipt-manifest
  while IFS= read -r name || [[ -n "$name" ]]; do
    [[ "$name" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || reject receipt-name
    case "$name" in output-before.manifest|output-after.manifest|push-authorization.json) receipt "$attempt_dir/$name" yes;; *) receipt "$attempt_dir/$name";; esac
  done <"$validation_dir/evidence-manifest.txt"
  entries=$(sort "$validation_dir/final-evidence-manifest.txt" | tr '\n' ' ')
  [[ "$entries" == 'F1-report.txt F2-report.txt F3-cleanup.log F3-report.txt F4-pages.manifest F4-report.txt ' ]] || reject final-manifest
  for name in F1-report.txt F2-report.txt F3-report.txt F3-cleanup.log; do receipt "$attempt_dir/$name"; done
  [[ $(tail -n1 "$attempt_dir/F1-report.txt") == APPROVE && $(tail -n1 "$attempt_dir/F2-report.txt") == APPROVE && $(tail -n1 "$attempt_dir/F3-report.txt") == APPROVE && $(tail -n1 "$attempt_dir/F3-cleanup.log") == cleanup=complete ]] || reject prerequisite-state
  [[ ! -e "$attempt_dir/F4-pages.manifest" && ! -e "$attempt_dir/F4-report.txt" ]] || reject existing-f4
  cmp -s "$attempt_dir/output-before.manifest" "$attempt_dir/output-after.manifest" || reject output-drift
  reject_secret_evidence "$attempt_dir"
  original=$(awk -F= '$1=="original_root" {n++; v=substr($0,15)} END {if(n==1 && v!="") print v; else exit 1}' "$attempt_dir/metadata.env") || reject metadata
  [[ -d "$original" ]] || reject original-root
  printf '%s\n' "$original"
}

filter() { case "$1" in threads) printf '%s' '.data.repository.pullRequest.reviewThreads';; reviews) printf '%s' '.data.repository.pullRequest.reviews';; checks) printf '%s' '.data.repository.pullRequest.commits.nodes[0].commit.statusCheckRollup.contexts';; *) reject kind;; esac; }
page() {
  local query=$1 cursor=$2 out=$3 owner=${repo%%/*} name=${repo##*/}
  if [[ "$cursor" == null ]]; then gh api graphql -f "owner=$owner" -f "name=$name" -F "number=$pr" -F cursor:=null -f "query=$query" >"$out" 2>/dev/null || reject graphql-request; else gh api graphql -f "owner=$owner" -f "name=$name" -F "number=$pr" -f "cursor=$cursor" -f "query=$query" >"$out" 2>/dev/null || reject graphql-request; fi
}
valid_page() {
  local kind=$1 file=$2 path; path=$(filter "$kind")
  jq -e --arg kind "$kind" --arg sha "$tested_sha" 'type=="object" and ((has("errors")|not) or .errors==null or .errors==[]) and .data.repository.pullRequest != null and (if $kind=="checks" then (.data.repository.pullRequest.commits.nodes|type=="array" and length==1 and .[0].commit.oid==$sha) else true end)' "$file" >/dev/null 2>&1 || reject graphql-error
  jq -e "($path) as \$c | (\$c.nodes|type==\"array\") and (\$c.pageInfo|type==\"object\" and (.hasNextPage|type==\"boolean\") and ((.hasNextPage==false and (.endCursor==null or (.endCursor|type==\"string\"))) or (.hasNextPage==true and (.endCursor|type==\"string\" and length>0))))" "$file" >/dev/null 2>&1 || reject page-info
}
node_gate() {
  local kind=$1 file=$2
  case "$kind" in
    threads) jq -e '.data.repository.pullRequest.reviewThreads.nodes|all(.[]; type=="object" and .isResolved==true)' "$file" >/dev/null 2>&1 || reject unresolved-thread;;
    reviews) jq -e '.data.repository.pullRequest.reviews.nodes|all(.[]; type=="object" and (.state|type=="string") and (.submittedAt|type=="string") and (.author.login|type=="string" and length>0))' "$file" >/dev/null 2>&1 || reject review-shape; jq -c '.data.repository.pullRequest.reviews.nodes[]|{state,submittedAt,login:.author.login}' "$file" >>"$tmp/reviews";;
    checks) jq -e '.data.repository.pullRequest.commits.nodes[0].commit.statusCheckRollup.contexts.nodes|all(.[]; type=="object" and (.__typename=="CheckRun" or .__typename=="StatusContext"))' "$file" >/dev/null 2>&1 || reject check-shape; jq -c '.data.repository.pullRequest.commits.nodes[0].commit.statusCheckRollup.contexts.nodes[]' "$file" >>"$tmp/checks";;
  esac
}
fetch() {
  local kind=$1 query=$2 cursor=null next path file seen="$tmp/$1.seen"; path=$(filter "$kind"); : >"$seen"
  while :; do
    ((pages < max_pages)) || reject page-limit; pages=$((pages+1)); file="$tmp/page-$pages-$kind.json"; page "$query" "$cursor" "$file"; valid_page "$kind" "$file"; node_gate "$kind" "$file"
    next=$(jq -r "$path.pageInfo.endCursor // \"-\"" "$file"); printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$pages" "$kind" "$cursor" "$(jq -r "$path.pageInfo.hasNextPage" "$file")" "$next" "$(sha256sum "$file"|awk '{print $1}')" "$(basename "$file")" >>"$tmp/manifest"
    [[ $(jq -r "$path.pageInfo.hasNextPage" "$file") == true ]] || return 0
    next=$(jq -r "$path.pageInfo.endCursor" "$file"); grep -Fqx "$next" "$seen" && reject cursor-loop; printf '%s\n' "$next" >>"$seen"; cursor=$next
  done
}
terminal() {
  jq -s -e 'all(.[]; .state=="APPROVED" or .state=="COMMENTED" or .state=="DISMISSED" or .state=="CHANGES_REQUESTED") and (sort_by(.login,.submittedAt)|group_by(.login)|all(.[]; .[-1].state!="CHANGES_REQUESTED"))' "$tmp/reviews" >/dev/null 2>&1 || reject changes-requested
  jq -s -e --arg required "$required_one" 'all(.[]; if .__typename=="CheckRun" then .status=="COMPLETED" and (.conclusion=="SUCCESS" or .conclusion=="NEUTRAL" or .conclusion=="SKIPPED") elif .__typename=="StatusContext" then .state=="SUCCESS" else false end) and ([.[]|select(.__typename=="CheckRun" and .name==$required)]|length==1)' "$tmp/checks" >/dev/null 2>&1 || reject terminal-checks
}
publish() {
  local file kind expected
  for kind in threads reviews checks; do expected=$(awk -F '\t' -v k="$kind" '$2==k && $4=="false" {n++} END {print n+0}' "$tmp/manifest"); [[ "$expected" == 1 ]] || reject terminal-pages; done
  for file in "$tmp"/page-*.json; do chmod 0600 "$file"; mv "$file" "$attempt_dir/$(basename "$file")"; done
  chmod 0600 "$tmp/manifest"; mv "$tmp/manifest" "$attempt_dir/F4-pages.manifest"
  printf 'tested_sha=%s\nverifier=F4\nstarted_at_utc=%s\nfinished_at_utc=%s\npages=%s\nAPPROVE\n' "$tested_sha" "$(date -u +%FT%TZ)" "$(date -u +%FT%TZ)" "$pages" >"$attempt_dir/F4-report.txt"; chmod 0600 "$attempt_dir/F4-report.txt"
}
audit() {
  local original
  need jq; need gh; need git; need rg; need sha256sum; need stat
  [[ "$repo" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ && "$pr" =~ ^[1-9][0-9]*$ && "$tested_sha" =~ ^[0-9a-f]{40,64}$ && "$base_sha" =~ ^[0-9a-f]{40,64}$ && -d "$attempt_dir" ]] || reject arguments
  original=$(receipts); git fetch origin +refs/heads/main:refs/remotes/origin/main +refs/heads/feat/production-hardening:refs/remotes/origin/feat/production-hardening >/dev/null 2>&1 || reject git-fetch
  [[ $(git rev-parse refs/remotes/origin/main) == "$base_sha" && $(git rev-parse refs/remotes/origin/feat/production-hardening) == "$tested_sha" && $(git -C "$original" rev-parse HEAD) == "$tested_sha" ]] || reject git-sha
  tmp=$(mktemp -d "$attempt_dir/.github-terminal-audit.XXXXXX"); : >"$tmp/reviews"; : >"$tmp/checks"; : >"$tmp/manifest"; fetch threads "$threads_query"; fetch reviews "$reviews_query"; fetch checks "$checks_query"; terminal
  gh pr view "$pr" --repo "$repo" --json state,isDraft,baseRefName,headRefName,headRefOid,mergeable,mergeStateStatus >"$tmp/pr.json" 2>/dev/null || reject pr-query
  jq -e --arg sha "$tested_sha" '.state=="OPEN" and .isDraft==false and .baseRefName=="main" and .headRefName=="feat/production-hardening" and .headRefOid==$sha and .mergeable=="MERGEABLE" and .mergeStateStatus=="CLEAN"' "$tmp/pr.json" >/dev/null 2>&1 || reject pr-state; publish
}

self_test() {
  local sha=1111111111111111111111111111111111111111 file
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/github-terminal-audit.XXXXXX"); tested_sha=$sha; repo=owner/name; pr=5; : >"$tmp/reviews"; : >"$tmp/checks"; : >"$tmp/manifest"
  printf '%s\n' '{"data":{"repository":{"pullRequest":{"reviewThreads":{"nodes":[{"isResolved":true}],"pageInfo":{"hasNextPage":true,"endCursor":"t2"}}}}}}' >"$tmp/t-null.json"
  printf '%s\n' '{"data":{"repository":{"pullRequest":{"reviewThreads":{"nodes":[{"isResolved":true}],"pageInfo":{"hasNextPage":false,"endCursor":null}}}}}}' >"$tmp/t-t2.json"
  printf '%s\n' '{"data":{"repository":{"pullRequest":{"reviews":{"nodes":[{"state":"APPROVED","submittedAt":"2026-01-01T00:00:00Z","author":{"login":"reviewer"}}],"pageInfo":{"hasNextPage":false,"endCursor":null}}}}}}' >"$tmp/r-null.json"
  jq -n --arg sha "$sha" '{data:{repository:{pullRequest:{commits:{nodes:[{commit:{oid:$sha,statusCheckRollup:{contexts:{nodes:[{__typename:"CheckRun",name:"security / lint-and-scan",status:"COMPLETED",conclusion:"SUCCESS"}],pageInfo:{hasNextPage:false,endCursor:null}}}}}]}}}}}' >"$tmp/c-null.json"
  case ${AUDIT_CASE:-good} in
    pending) jq '.data.repository.pullRequest.commits.nodes[0].commit.statusCheckRollup.contexts.nodes[0].status="IN_PROGRESS"' "$tmp/c-null.json" >"$tmp/x"; mv "$tmp/x" "$tmp/c-null.json";;
    failed) jq '.data.repository.pullRequest.commits.nodes[0].commit.statusCheckRollup.contexts.nodes[0].conclusion="FAILURE"' "$tmp/c-null.json" >"$tmp/x"; mv "$tmp/x" "$tmp/c-null.json";;
    unresolved) jq '.data.repository.pullRequest.reviewThreads.nodes[0].isResolved=false' "$tmp/t-t2.json" >"$tmp/x"; mv "$tmp/x" "$tmp/t-t2.json";;
    malformed) printf '%s\n' '{"errors":[{}]}' >"$tmp/r-null.json";;
    cycle) printf '%s\n' '{"data":{"repository":{"pullRequest":{"reviewThreads":{"nodes":[{"isResolved":true}],"pageInfo":{"hasNextPage":true,"endCursor":"loop"}}}}}}' >"$tmp/t-null.json"; cp "$tmp/t-null.json" "$tmp/t-loop.json";;
    changes) jq '.data.repository.pullRequest.reviews.nodes[0].state="CHANGES_REQUESTED"' "$tmp/r-null.json" >"$tmp/x"; mv "$tmp/x" "$tmp/r-null.json";;
    wrong-sha) jq '.data.repository.pullRequest.commits.nodes[0].commit.oid="2222222222222222222222222222222222222222"' "$tmp/c-null.json" >"$tmp/x"; mv "$tmp/x" "$tmp/c-null.json";;
    duplicate-required) jq '.data.repository.pullRequest.commits.nodes[0].commit.statusCheckRollup.contexts.nodes += [.data.repository.pullRequest.commits.nodes[0].commit.statusCheckRollup.contexts.nodes[0]]' "$tmp/c-null.json" >"$tmp/x"; mv "$tmp/x" "$tmp/c-null.json";;
    missing-required) jq '.data.repository.pullRequest.commits.nodes[0].commit.statusCheckRollup.contexts.nodes=[]' "$tmp/c-null.json" >"$tmp/x"; mv "$tmp/x" "$tmp/c-null.json";;
    old-required) jq '.data.repository.pullRequest.commits.nodes[0].commit.statusCheckRollup.contexts.nodes[0].name="e2e-public-install / public-install"' "$tmp/c-null.json" >"$tmp/x"; mv "$tmp/x" "$tmp/c-null.json";;
  esac
  gh() { local q='' c=null x; for x in "$@"; do case "$x" in query=*) q=${x#query=};; cursor=*) c=${x#cursor=};; cursor:=null) c=null;; esac; done; case "$q" in *reviewThreads*) cat "$tmp/t-$c.json";; *"reviews(first:100"*) cat "$tmp/r-$c.json";; *statusCheckRollup*) cat "$tmp/c-$c.json";; esac; }
  pages=0; fetch threads "$threads_query"; fetch reviews "$reviews_query"; fetch checks "$checks_query"; terminal
  [[ "$pages" == 4 ]] || return 1; printf '%s\n' 'SELFTEST pagination=PASS'
  jq -e '.data.repository.pullRequest.commits.nodes[0].commit.statusCheckRollup.contexts.nodes[0].status != "COMPLETED"' "$tmp/c-null.json" >/dev/null && return 1; printf '%s\n' 'SELFTEST pending-check=PASS'
  jq -e '.data.repository.pullRequest.reviewThreads.nodes[0].isResolved == false' "$tmp/t-t2.json" >/dev/null && return 1; printf '%s\n' 'SELFTEST unresolved-review=PASS'
  if [[ ${AUDIT_CASE:-good} == good ]]; then
    local bad marker
    for bad in pending failed unresolved malformed cycle changes wrong-sha duplicate-required missing-required old-required; do
      AUDIT_CASE="$bad" "$0" --self-test >/dev/null 2>&1 && return 1
      case "$bad" in pending) marker='pending-check';; failed) marker='failed-check';; unresolved) marker='unresolved-review';; malformed) marker='malformed-error';; cycle) marker='cursor-loop';; changes) marker='changes-requested';; wrong-sha) marker='wrong-sha';; duplicate-required) marker='duplicate-required-check';; missing-required) marker='missing-required-check';; old-required) marker='old-required-check';; esac
      printf 'SELFTEST %s=PASS\n' "$marker"
    done
    if (receipt "$tmp/missing-receipt"); then return 1; fi; printf '%s\n' 'SELFTEST missing-receipt=PASS'
    printf 'tested_sha=%s\n' "$sha" >"$tmp/secure"; chmod 0600 "$tmp/secure"; ln -s secure "$tmp/symlink"; if (receipt "$tmp/symlink"); then return 1; fi; printf '%s\n' 'SELFTEST symlink-receipt=PASS'
    ln "$tmp/secure" "$tmp/hardlink"; if (receipt "$tmp/hardlink"); then return 1; fi; printf '%s\n' 'SELFTEST hardlink-receipt=PASS'
    mkfifo "$tmp/special"; if (receipt "$tmp/special"); then return 1; fi; printf '%s\n' 'SELFTEST special-receipt=PASS'
    mkdir "$tmp/secret-dir"; printf '%s\n' 'AGE-SECRET-KEY-TESTFIXTURE' >"$tmp/secret-dir/secret.log"; if (reject_secret_evidence "$tmp/secret-dir"); then return 1; fi; printf '%s\n' 'SELFTEST secret-log=PASS'
    if "$0" >/dev/null 2>&1; then return 1; fi; printf '%s\n' 'SELFTEST missing-invocation=PASS'
  fi
  printf '%s\n' 'SELFTEST complete=PASS'
}

if [[ ${1:-} == --self-test ]]; then [[ $# == 1 ]] || { usage >&2; exit 64; }; self_test; exit 0; fi
while [[ $# -gt 0 ]]; do case "$1" in --repo) repo=${2:-}; shift 2;; --pr) pr=${2:-}; shift 2;; --tested-sha) tested_sha=${2:-}; shift 2;; --base-sha) base_sha=${2:-}; shift 2;; --attempt-dir) attempt_dir=${2:-}; shift 2;; *) usage >&2; exit 64;; esac; done
audit
