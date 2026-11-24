#!/bin/sh
set -eu

REPOS_FILE=/etc/tsgit-poll/repos
STATE=/state
API=https://kubernetes.default.svc
NS="${NS:-tekton-pipelines}"
TOKEN=$(cat /var/run/secrets/kubernetes.io/serviceaccount/token)
CACERT=/var/run/secrets/kubernetes.io/serviceaccount/ca.crt

mkdir -p "$STATE"

while read -r name url branch _; do
  case "${name:-}" in
    ''|\#*) continue ;;
  esac
  case "$name" in
    *[!a-z0-9-]*) echo "poll: skipping invalid repo name '$name'"; continue ;;
  esac
  branch=${branch:-main}
  ref="refs/heads/$branch"

  body=$(curl -fsS --retry 3 --max-time 20 "$url/info/refs?service=git-upload-pack") || {
    echo "poll: $name: ls-remote HTTP fetch failed; skipping"
    continue
  }
  # pkt-line framing: strip the 4-hex length prefix of each line, then
  # pick the exact branch ref line. Tolerates refs longer than 40 hex (sha256 oids).
  sha=$(printf '%s' "$body" | tr -d '\r' | sed -e 's/^[0-9a-fA-F]\{4\}//' | awk -v ref="$ref" '$2 == ref {print $1}' | head -1)
  if [ -z "$sha" ]; then
    echo "poll: $name: ref $ref not advertised or unparsable"
    continue
  fi

  state_file="$STATE/$name.sha"
  last=$(cat "$state_file" 2>/dev/null || true)
  if [ "$sha" = "$last" ]; then
    echo "poll: $name @ $branch unchanged ($sha)"
    continue
  fi
  echo "poll: $name @ $branch ${last:-<none>} -> $sha, creating PipelineRun"

  payload=$(cat <<JSON
{"apiVersion":"tekton.dev/v1","kind":"PipelineRun","metadata":{"generateName":"${name}-","namespace":"$NS","labels":{"ci.tsgit/repo":"$name","ci.tsgit/branch":"$branch"},"annotations":{"ci.tsgit/revision":"$sha"}},"spec":{"pipelineRef":{"name":"validate-repo"},"taskRunTemplate":{"serviceAccountName":"pipeline-runner","podTemplate":{"automountServiceAccountToken":false,"securityContext":{"seccompProfile":{"type":"RuntimeDefault"}}}},"params":[{"name":"repo","value":"$url"},{"name":"revision","value":"$sha"}],"workspaces":[{"name":"source","emptyDir":{}},{"name":"tools","emptyDir":{}}],"timeouts":{"pipeline":"10m","tasks":"9m"}}}
JSON
)
  code=$(curl -s -o /tmp/resp -w '%{http_code}' --cacert "$CACERT" \
    -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
    -X POST "$API/apis/tekton.dev/v1/namespaces/$NS/pipelineruns" \
    --data "$payload")
  case "$code" in
    2*) printf '%s\n' "$sha" > "$state_file"; echo "poll: $name PipelineRun created" ;;
    *)  echo "poll: $name failed to create PipelineRun (HTTP $code): $(cat /tmp/resp)"; exit 1 ;;
  esac
done < "$REPOS_FILE"
