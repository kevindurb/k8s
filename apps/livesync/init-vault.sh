#!/bin/sh
# Idempotent vault bootstrap for the LiveSync CouchDB instance.
#
# Runs as a postStart hook on every container start, after the entrypoint has
# seeded the admin user from the environment. CouchDB may not be listening yet,
# so the first step waits for /_up, which is deliberately unauthenticated.
#
# Everything here is safe to repeat: the database creation tolerates 412, the
# user document is upserted with its current revision, and _security is a
# plain PUT. Failures are logged but do not kill the container, because a
# failed bootstrap shows up as a broken sync rather than a crash-looping pod
# that would also hide the CouchDB logs.

set -u

base='http://127.0.0.1:5984'
admin="${COUCHDB_USER}:${COUCHDB_PASSWORD}"
db="${COUCHDB_DATABASE:-obsidiannotes}"
user="${VAULT_USER:?VAULT_USER is required}"
pass="${VAULT_PASSWORD:?VAULT_PASSWORD is required}"

log() {
  echo "init-vault: $*"
}

# Escape a value for embedding in the JSON bodies below.
json_escape() {
  printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

i=0
until curl -fsS -o /dev/null "$base/_up" 2>/dev/null; do
  i=$((i + 1))
  if [ "$i" -ge 120 ]; then
    log "couchdb did not become ready; leaving initialisation for the next start"
    exit 0
  fi
  sleep 1
done

status=$(curl -sS -o /dev/null -w '%{http_code}' -u "$admin" -X PUT "$base/$db")
case "$status" in
  201|202|412) ;;
  *) log "database create returned $status" ;;
esac

doc="$base/_users/org.couchdb.user:$user"
rev=$(curl -sS -u "$admin" "$doc" | sed -n 's/.*"_rev":"\([^"]*\)".*/\1/p')

body="{\"name\":\"$(json_escape "$user")\",\"type\":\"user\",\"roles\":[],\"password\":\"$(json_escape "$pass")\""
if [ -n "$rev" ]; then
  body="$body,\"_rev\":\"$rev\""
fi
body="$body}"

status=$(curl -sS -o /dev/null -w '%{http_code}' -u "$admin" -X PUT \
  -H 'Content-Type: application/json' --data "$body" "$doc")
case "$status" in
  201|202) ;;
  *) log "user upsert returned $status" ;;
esac

security="{\"admins\":{\"names\":[],\"roles\":[\"_admin\"]},\"members\":{\"names\":[\"$(json_escape "$user")\"],\"roles\":[]}}"
status=$(curl -sS -o /dev/null -w '%{http_code}' -u "$admin" -X PUT \
  -H 'Content-Type: application/json' --data "$security" "$base/$db/_security")
case "$status" in
  200|201|202) ;;
  *) log "security update returned $status" ;;
esac

log "vault database '$db' ready for user '$user'"
