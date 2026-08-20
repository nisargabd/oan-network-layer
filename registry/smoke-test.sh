#!/usr/bin/env bash
# Smallest end-to-end check that the stack is usable: get an NO token, create a
# Participant, find it via search, suspend it, and confirm the suspension is visible.
# Mirrors steps 3 to 7 of API_SPECIFICATION.md.
set -euo pipefail

REGISTRY=${REGISTRY:-http://localhost:8081}
KEYCLOAK=${KEYCLOAK:-http://localhost:8080}
NO_USER=${NO_USER:-no-user}
NO_PASSWORD=${NO_PASSWORD:-no-user-password}
PID=${PID:-smoke-provider-001}

jsonget() { python3 -c "import json,sys;d=json.load(sys.stdin);print(eval('d'+'$1'))"; }

echo "1. token for $NO_USER"
TOKEN=$(curl -s -X POST "$KEYCLOAK/auth/realms/sunbird-rc/protocol/openid-connect/token" \
  -H "X-Forwarded-Host: keycloak:8080" -H "X-Forwarded-Proto: http" \
  -d "client_id=registry-frontend" -d "username=$NO_USER" \
  -d "password=$NO_PASSWORD" -d "grant_type=password" | jsonget "['access_token']")
test -n "$TOKEN"

echo "2. create participant $PID"
OSID=$(curl -s -X POST "$REGISTRY/api/v1/Participant" \
  -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  -d '{
    "participant_id": "'"$PID"'",
    "display_name": "Smoke Test Provider",
    "roles": ["provider"],
    "status": "active",
    "domain": "weather",
    "record_version": 1,
    "updated_at": "2026-08-19T10:00:00Z",
    "endpoint_url": "https://smoke.example.com/onix",
    "endpoint_type": "onix",
    "signing_public_key": "MCowBQYDK2VwAyEA3fS8bYhWEfmM7Zjk9x0EhAmvQKp3fMHXqTiA5xL1Qmw=",
    "signing_algorithm": "ed25519",
    "key_valid_from": "2026-08-19T00:00:00Z",
    "key_valid_until": "2027-08-19T00:00:00Z"
  }' | jsonget "['result']['Participant']['osid']")
echo "   osid=$OSID"

echo "3. search for it (public endpoint, no token)"
FOUND=$(curl -s -X POST "$REGISTRY/api/v1/Participant/search" \
  -H "Content-Type: application/json" \
  -d '{"filters": {"participant_id": {"eq": "'"$PID"'"}}}' | jsonget "[0]['status']")
test "$FOUND" = "active" || { echo "   expected active, got '$FOUND'"; exit 1; }

echo "4. suspend it (full replace, status flipped to inactive)"
curl -s -o /dev/null -X PUT "$REGISTRY/api/v1/Participant/$OSID" \
  -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  -d '{
    "osid": "'"$OSID"'",
    "participant_id": "'"$PID"'",
    "display_name": "Smoke Test Provider",
    "roles": ["provider"],
    "status": "inactive",
    "domain": "weather",
    "record_version": 2,
    "updated_at": "2026-08-19T11:00:00Z",
    "endpoint_url": "https://smoke.example.com/onix",
    "endpoint_type": "onix",
    "signing_public_key": "MCowBQYDK2VwAyEA3fS8bYhWEfmM7Zjk9x0EhAmvQKp3fMHXqTiA5xL1Qmw=",
    "signing_algorithm": "ed25519",
    "key_valid_from": "2026-08-19T00:00:00Z",
    "key_valid_until": "2027-08-19T00:00:00Z"
  }'

AFTER=$(curl -s -X POST "$REGISTRY/api/v1/Participant/search" \
  -H "Content-Type: application/json" \
  -d '{"filters": {"participant_id": {"eq": "'"$PID"'"}}}' | jsonget "[0]['status']")
test "$AFTER" = "inactive" || { echo "   expected inactive, got '$AFTER'"; exit 1; }

echo "PASS - create, search and suspend all work. Clean up with:"
echo "  curl -X DELETE $REGISTRY/api/v1/Participant/$OSID -H \"Authorization: Bearer \$TOKEN\""
