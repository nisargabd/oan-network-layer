# OAN Registry - local dev stack

Brings up the Registry Service (Sunbird RC core) and only the services it depends on:
PostgreSQL, Keycloak and Elasticsearch. ONIX is not here yet - it will be added later as
a sibling directory under `network-layer/`.

The API flows this stack supports are documented in `API_SPECIFICATION.md` (Network
Operator creates Providers, anyone searches them, Network Operator activates /
deactivates / removes them).

`WALKTHROUGH.md` is the handover document: what was built and why, the schema design and its
trade-offs, every endpoint, the end-to-end flow, and the verified behaviour of this deployment
including where it diverges from the specification. Read that if you need to change the
registry; this file is only how to run it.

## What runs

| Service | Host address | Purpose |
|---|---|---|
| registry | http://localhost:8081 | Participant records, lookup, key material |
| keycloak | http://localhost:8080/auth | Tokens and role checks (`admin`, `network_operator`) |
| db (postgres) | localhost:5432 | Registry and Keycloak storage |
| es (elasticsearch) | http://localhost:9200 | Backs the `/search` filters |

Credentials, DIDs, certificates, claims, notifications and file storage are all disabled -
this stack is participant records and lookup only.

## Prerequisites

- Docker and Docker Compose
- Around 4 GB free RAM (Elasticsearch and Keycloak are the heavy parts)
- `python3` on the host, used by `smoke-test.sh` to read JSON responses

## Bring it up

1. Copy the env file and fill in the required values - `POSTGRES_PASSWORD`,
   `KEYCLOAK_ADMIN_PASSWORD`, `REGISTRY_DEFAULT_USER_PASSWORD`. Compose refuses to start
   while any of them is empty. `KEYCLOAK_SECRET` is filled in at step 3.

   ```bash
   cp .env.example .env
   ```

   No credentials live in `docker-compose.yml`; `.env` is gitignored. `POSTGRES_PASSWORD` is
   baked into `db-data/` on first start, so changing it later means deleting that directory.

2. Start Keycloak and the database first, since the registry needs a client secret that
   only exists once Keycloak has imported its realm:

   ```bash
   docker compose up -d db keycloak es
   ```

3. Get the `admin-api` client secret:

   - Open http://localhost:8080/auth and log in with `KEYCLOAK_ADMIN_USER` / `KEYCLOAK_ADMIN_PASSWORD` from `.env`
   - Switch to the `sunbird-rc` realm
   - Go to **Clients** -> **admin-api** -> **Credentials**
   - Click **Regenerate Secret** and copy the value
   - Put it in `.env` as `KEYCLOAK_SECRET=<value>`

4. Start the registry:

   ```bash
   docker compose up -d registry
   docker compose ps
   ```

5. Confirm the registry is healthy and the schema loaded:

   ```bash
   curl -s http://localhost:8081/health
   curl -s http://localhost:8081/api/docs/swagger.json | grep -o '/api/v1/Participant[^"]*' | sort -u
   ```

## Network Operator user

Steps 1 and 2 of `API_SPECIFICATION.md` (creating the `network_operator` realm role and the
Network Operator's user) are already applied by `imports/realm-export.json`:

- realm role `network_operator`
- user `no-user`, password `no-user-password`, holding that role

Dev-only credentials, and the one place a password is still written into a file: Keycloak's
realm import needs it inline, so it cannot come from `.env`. For anything beyond local dev,
drop the `no-user` block from `imports/realm-export.json` and create the user through the
admin console instead, as steps 1 and 2 of the specification describe.

## Hit the endpoints

Get a token:

```bash
curl -s -X POST "http://localhost:8080/auth/realms/sunbird-rc/protocol/openid-connect/token" \
  -H "X-Forwarded-Host: keycloak:8080" -H "X-Forwarded-Proto: http" \
  -d "client_id=registry-frontend" -d "username=no-user" \
  -d "password=no-user-password" -d "grant_type=password"
```

The `X-Forwarded-*` headers matter when calling from the host: without them the issued
token's `iss` claim is `http://localhost:8080/...`, which does not match what the registry
expects internally (`http://keycloak:8080/auth/realms/sunbird-rc`), and every write is
rejected with `401`.

Then follow steps 4 to 7 of `API_SPECIFICATION.md` for create, search, suspend and delete.
Note that `/api/v1/Participant/search` is public - send either a real token or no
`Authorization` header at all, never an empty one.

## Verify the whole flow at once

```bash
./smoke-test.sh
```

Gets a token, creates a Participant, finds it via search, suspends it, and confirms the
suspension is visible. Prints `PASS` and the cleanup command, or exits non-zero on the
first step that misbehaves.

## Postman collection

`postman/OAN-Registry.postman_collection.json` - 36 requests covering the whole flow, every
one with assertions, and self-cleaning so it can be run repeatedly.

Import it into Postman and hit Run, or run it headless:

```bash
npx newman run postman/OAN-Registry.postman_collection.json
```

Verified against this stack: 36 requests, 70 assertions, 0 failures.

It covers health and the generated API surface, the Network Operator token, creating the
Network Operator and a Provider, five search shapes, read by osid, read by token, suspend
and reactivate, invite, delete, and the rejection cases (no token, wrong issuer, missing
field, bad enum value, duplicate id, empty Authorization header, unknown osid).

Collection variables point at `localhost:8081` / `localhost:8080` and carry the token and
osids between requests. The first request stamps a `run_id` that is baked into every
`participant_id`, because a deleted record's row physically remains and re-using an id
returns 500.

Three things the collection had to work around, all verified here:

- **`PUT` is a field-level merge, not a full replace.** Fields you send are overwritten, fields
  you omit keep their stored values, and validation runs on the merged document - so a partial
  body like `{"osid": ..., "status": "inactive"}` is accepted and leaves everything else intact.
  Arrays are replaced wholesale rather than appended to, and clearing a field means sending it
  explicitly (`"domain": ""`). `API_SPECIFICATION.md` describes PUT as a full replace that would
  wipe omitted fields; that is not what the running registry does.

- **`/search` is eventually consistent.** It is served by Elasticsearch, which refreshes
  about once a second, so a search fired immediately after a write can read stale data. The
  collection forces `POST {{es_url}}/_refresh` before searching, and verifies writes through
  `GET /{osid}`, which reads postgres directly. Real clients should not assume a write is
  searchable instantly.
- **JSESSIONID is equivalent to a bearer token.** The registry issues a session cookie on the
  first token-authenticated call, and afterwards accepts that cookie *instead* of a token -
  `POST` and `DELETE` on Participant both succeed with only the cookie and no
  `Authorization` header. Any client with a cookie jar (Postman, newman, a browser) therefore
  stays authenticated, which silently defeats the no-token tests. The collection disables
  cookies on every request, which is also how a real client such as ONIX behaves. Worth
  raising before this is exposed anywhere beyond dev.

Where observed behaviour differs from `API_SPECIFICATION.md`, the request description says so.
The two differences found: `/search` returns `{ data: [...], totalCount: n }` rather than a
bare array, and `totalCount` reads 0 with the Elasticsearch provider (use `data.length`); and
a duplicate `participant_id` comes back as `500` with a postgres `duplicate key` message, not
a clean `400`.

## Participant schema

`schemas/Participant.json` is the single entity in this registry. There is no separate
Provider or NetworkOperator entity - `roles` on the record is what distinguishes them.

| Field | Required | Notes |
|---|---|---|
| `participant_id` | yes | Business identifier, unique across the network |
| `display_name` | yes | Human-readable name |
| `roles` | yes | One or more of `network_operator`, `provider`, `consumer` |
| `status` | yes | `active` or `inactive` - the only lifecycle field, held at record level |
| `record_version` | yes | Version counter, starts at 1 |
| `updated_at` | yes | ISO-8601 timestamp |
| `domain` | no | `weather`, `market`, `credit`, `advisory`, ... |
| `endpoint_url` | no | Where requests are sent once resolved |
| `endpoint_type` | no | `onix`, `callback` or `api` |
| `signing_public_key` | no | Base64 public key a receiver verifies signatures with |
| `signing_algorithm` | no | `ed25519` |
| `key_valid_from` / `key_valid_until` | no | Validity window of the signing key |

**Unknown fields are rejected.** `additionalProperties: false` is set, so a typo like
`endpointurl` returns 400 rather than being stored as its own column - without it the record
would resolve with no endpoint at all, which is a silent failure for anything trusting the
registry for endpoints or keys. This is also why the registry's own system fields (`osid`,
`osOwner`, `osCreatedAt`, `osUpdatedAt`, `osCreatedBy`, `osUpdatedBy`, `_status`) are declared
in the schema: PUT validates the *merged* document, which carries them, so leaving them
undeclared makes every update fail with `extraneous key [osUpdatedAt] is not permitted`.

**The schema is deliberately flat.** SunbirdRC stores an entity as a graph, so every nested
object becomes its own node with its own osid - a participant with one endpoint object and one
key object came back as three osids, and the parent row carried `endpoints_arr_osid` /
`keys_arr_osid` pointers. There is no config flag to turn that off. Keeping every field scalar
(or an array of scalars, like `roles`) means one participant is one record with exactly one
osid. Verified: a flat record's JSON contains the string `osid` once.

The trade-off is one endpoint and one signing key per participant. Key rotation overwrites
rather than holding the old and new key side by side; if overlapping keys are needed later,
that is the point to revisit this - either a second set of `signing_public_key_next` fields or
accepting nested objects and their child osids.

`_osConfig` gives write access to `admin` and `network_operator` only, with no
`ownershipAttributes` and no `attestationPolicies` - so there is no self-registration path
and no claims workflow, matching the model in the specification.

Changing the schema means restarting the registry:

```bash
docker compose restart registry
```

## Reset

```bash
docker compose down
sudo rm -rf db-data/
```

Drops every participant record and the Keycloak realm state, so the realm import and the
client secret step have to be redone.
