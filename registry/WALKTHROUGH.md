# OAN Registry — Implementation Walkthrough

A record of what was built, why each decision was made, how the stack is run, and what the
running system actually does. `README.md` is the short operational guide; this document is the
handover — read it if you need to understand or change the registry, not just start it.

- **Story:** [OpenAgriNet/engineering-tracker#33 — Implement Registry Service](https://github.com/OpenAgriNet/engineering-tracker/issues/33)
- **Tasks:** #42 (docker compose), #43 (schema), #44 (local test), #45 (flow test)
- **Reference deployment:** `rc-devops/deploy-as-code/docker/v2/registry_and_credentialling`
- **API contract:** `API_SPECIFICATION.md`
- **Location:** `network-layer/registry/`

---

## 1. What this is

The OAN Registry is the network's directory. Every participant on the network — network
operators, providers, consumers — has one record in it. A record answers three questions for
anyone who looks it up:

1. **Who are you?** `participant_id`, `display_name`, `roles`, `domain`
2. **Where do I reach you?** `endpoint_url`, `endpoint_type`
3. **How do I know a request really came from you?** `signing_public_key`, `signing_algorithm`
   and the key's validity window

Everything else in the registry exists to serve those three answers: authentication so only a
Network Operator can write records, search so a consumer can find providers, and lifecycle
fields so a participant can be suspended without being deleted.

The implementation is **Sunbird RC** (`ghcr.io/sunbird-rc/sunbird-rc-core:v2.0.0`) — the same
core the reference deployment uses. We do not write registry application code. We write a JSON
schema; Sunbird RC reads it at boot and generates the entire REST API for it. That is the single
most important thing to understand about this stack: **the schema is the product.**

### Scope

| In scope | Out of scope (deliberately) |
|---|---|
| Registry service | ONIX adapter — added later as a sibling compose |
| Postgres (records) | Verifiable credentials / certificates |
| Keycloak (tokens, roles) | DIDs, signature service, claims / attestation |
| Elasticsearch (search) | Notifications, file storage, webhooks, async |

Every optional Sunbird RC subsystem is explicitly switched off in the compose file. The
reference deployment brings up ~10 services because it also does credentialling; this stack is
four services because it only does participant records and lookup.

---

## 2. Layout

```
network-layer/registry/
├── docker-compose.yml                        # the stack: db, es, keycloak, registry
├── .env.example                              # every tunable; no secrets, REQUIRED markers
├── .env                                      # real values — gitignored
├── .gitignore                                # .env, db-data/
├── schemas/
│   └── Participant.json                      # THE contract — mounted into the registry
├── imports/
│   └── realm-export.json                     # Keycloak realm: clients, roles, dev user
├── postman/
│   └── OAN-Registry.postman_collection.json  # 36 requests, 70 assertions, end to end
├── smoke-test.sh                             # 30-second curl check of the happy path
├── README.md                                 # how to run it
└── WALKTHROUGH.md                            # this file
```

`network-layer/` is the parent because the registry is one component of the network layer;
ONIX will sit beside it, not inside it.

---

## 3. Step 1 — the schema

`schemas/Participant.json` is mounted at `/home/sunbirdrc/config/public/_schemas`. On boot
Sunbird RC reads every file in that directory and generates a full REST API per entity. The
filename becomes the entity name, so `Participant.json` produces `/api/v1/Participant`.

### One entity, not three

There is no `Provider` schema and no `NetworkOperator` schema. A participant's `roles` array is
what distinguishes them. A single entity means one endpoint to secure, one search index, one
uniqueness constraint, and a participant that is both a provider and a consumer is one record
rather than two that can drift apart.

### Required fields

Nine fields are required:

| Field | Type | Notes |
|---|---|---|
| `participant_id` | string | Business identifier. Unique across the network — enforced by a DB index, not just validation |
| `display_name` | string | Human-readable name |
| `roles` | array of enum | One or more of `network_operator`, `provider`, `consumer`; `minItems: 1` |
| `status` | enum | `active` or `inactive` — the only lifecycle field |
| `record_version` | integer | Version counter, starts at 1, `minimum: 1` |
| `updated_at` | date-time | ISO-8601 |
| `signing_public_key` | string | Base64 public key a receiver verifies signatures with |
| `endpoint_url` | string | Where requests are sent once resolved |
| `domain` | string | `weather`, `market`, `credit`, `advisory`, … |

Optional: `endpoint_type` (`onix` / `callback` / `api`), `signing_algorithm` (`ed25519`),
`key_valid_from`, `key_valid_until`.

`signing_public_key` and `endpoint_url` are required on purpose. A participant record that
resolves to no endpoint or no key is worse than no record at all — a caller gets a successful
lookup and then cannot reach or verify the participant. Making them required moves that failure
from runtime to write time.

### The schema is flat — and that was a design decision

The first version had nested objects: an `endpoints[]` array of endpoint objects and a `keys[]`
array of key objects. It worked, but a search response came back like this:

```json
{ "osid": "1-abc...",
  "endpoints": [ { "osid": "1-def...", "endpoint_url": "..." } ],
  "keys":      [ { "osid": "1-ghi...", "signing_public_key": "..." } ] }
```

Three osids for one participant. **Sunbird RC stores an entity as a graph** (via sqlg), so every
nested object becomes its own vertex with its own primary key, and the parent row carries pointer
columns — `endpoints_arr_osid`, `keys_arr_osid`. In postgres that is real, separate tables:
`V_Participant`, `V_endpoints`, `V_keys`, plus `E_*` edge tables.

There is no configuration flag that turns this off. The only way to get one osid per record is
to have nothing to nest: **every field is a scalar, or an array of scalars** (`roles` is fine —
strings, not objects). Verified: a flat record's JSON contains the string `osid` exactly once.

The trade-off, stated plainly: **one endpoint and one signing key per participant.** Key
rotation overwrites rather than holding old and new side by side. If overlapping keys are needed
later, that is the moment to revisit this — either add `signing_public_key_next` fields, or
accept nested objects and their child osids.

Also removed along the way: `record_id` (redundant with `participant_id` + `osid`), `key_id`,
`key_type`, and a per-key `status`. Status is a property of the participant, not of a key.

### `additionalProperties: false`

Unknown fields are rejected with `400`. Without it, a typo like `endpointurl` is silently stored
as its own column and the record resolves with no endpoint — a silent failure in exactly the
path that matters most.

This has one non-obvious consequence. `PUT` validates the **merged** document, and the merged
document carries the registry's own system fields. So `osid`, `osOwner`, `osCreatedAt`,
`osUpdatedAt`, `osCreatedBy`, `osUpdatedBy` and `_status` all have to be **declared as schema
properties** — otherwise every update fails with:

```
extraneous key [osUpdatedAt] is not permitted
```

Declaring them does not weaken the check: a genuine typo is still rejected. This is the fix for
that error, and the reason those seven properties are in the schema.

### `_osConfig`

```json
"_osConfig": {
  "systemFields":      ["osCreatedAt", "osUpdatedAt", "osCreatedBy", "osUpdatedBy"],
  "uniqueIndexFields": ["participant_id"],
  "indexFields":       ["status", "domain"],
  "roles":             ["admin", "network_operator"],
  "inviteRoles":       ["admin", "network_operator"]
}
```

- `roles` — only `admin` and `network_operator` may write. There is no self-registration path.
- `uniqueIndexFields` — creates a DB unique index on `participant_id`, so duplicates are blocked
  at the storage layer.
- `indexFields` — the fields search filters on most.
- No `ownershipAttributes` and no `attestationPolicies` — no participant-managed login, no
  claims/approval workflow. Matches the model in `API_SPECIFICATION.md`.

### Two gotchas that cost time

- **JSON has no comments.** `//` comments in `Participant.json` crash the registry at boot with
  a `DefinitionsManager.loadResourcesFromPath` parse error, and it crash-loops. Use the
  `comment` / `title` fields instead — both are in the schema now.
- **`manager_type=DefinitionsManager` means schemas load from disk at boot.** Editing the schema
  requires `docker compose restart registry`. Switching to `DBDefinitionsManager` would enable
  runtime schema APIs; we did not, because a schema change should be a reviewed file change, not
  an API call.

---

## 4. Step 2 — the compose file

`docker-compose.yml`, four services, derived from the reference deployment with everything not
needed for participant records stripped out.

| Service | Image | Host | Role |
|---|---|---|---|
| `db` | `postgres:14` | 5432 | Records + Keycloak storage |
| `es` | `elasticsearch:7.17.13` | 9200 | Backs `/search` |
| `keycloak` | `sunbird-rc-keycloak:latest` | 8080 | Tokens, realm roles |
| `registry` | `sunbird-rc-core:v2.0.0` | 8081 | The API |

Startup order is enforced with healthchecks and `depends_on: condition: service_healthy`, so the
registry does not come up before postgres, Elasticsearch and Keycloak can serve it.

### Configuration that matters

```yaml
- manager_type=DefinitionsManager     # schemas from the mounted directory
- registry_base_apis_enable=false     # no generic entity API; only the schema-generated ones
- expand_reference=false
- search_providerName=dev.sunbirdrc.registry.service.ElasticSearchService
- authentication_enabled=true
- OAUTH2_RESOURCES_0_URI=http://keycloak:8080/auth/realms/sunbird-rc
- OAUTH2_RESOURCES_0_PROPERTIES_ROLES_PATH=realm_access.roles
```

`OAUTH2_RESOURCES_0_URI` is the value that makes token validation strict about the issuer — see
the `X-Forwarded-Host` note in §6. `ROLES_PATH` tells the registry to read roles from
`realm_access.roles`, which is where the `_osConfig.roles` check looks.

Everything optional is off: `encryption_enabled`, `event_enabled`, `idgen_enabled`,
`claims_enabled`, `did_enabled`, `signature_enabled`, `certificate_enabled`,
`filestorage_enabled`, `notification_enabled`, `notification_async_enabled`, `async_enabled`,
`webhook_enabled`.

### No credentials in the compose file

Every secret comes from `.env`, which is gitignored. The four that have no safe default use
compose's fail-fast syntax:

```yaml
- POSTGRES_PASSWORD=${POSTGRES_PASSWORD:?set POSTGRES_PASSWORD in .env}
- KEYCLOAK_PASSWORD=${KEYCLOAK_ADMIN_PASSWORD:?set KEYCLOAK_ADMIN_PASSWORD in .env}
- sunbird_sso_admin_client_secret=${KEYCLOAK_SECRET:?set KEYCLOAK_SECRET in .env - regenerate it on the admin-api client in the Keycloak console}
- sunbird_keycloak_user_password=${REGISTRY_DEFAULT_USER_PASSWORD:?set REGISTRY_DEFAULT_USER_PASSWORD in .env}
```

`${VAR:?message}` makes compose refuse to start with that message rather than booting with a
blank password. Non-secret settings use `${VAR-default}` so the stack works out of the box:
image versions, host ports (`REGISTRY_HOST_PORT`, `KEYCLOAK_HOST_PORT`, `DB_HOST_PORT`,
`ES_HOST_PORT`), realm and client ids, directory names.

`.env.example` is committed and contains no secrets — required values are marked as such and
left blank.

**The one remaining exception:** `imports/realm-export.json` contains the dev user's password
inline, because Keycloak's realm import reads it from that file and cannot take it from an
environment variable. For anything beyond local dev, delete the `no-user` block and create the
user through the admin console instead — that is steps 1–2 of `API_SPECIFICATION.md`.

### Elasticsearch needs a named volume

Originally `es` had no volume. `docker compose down` then discarded the search index while
postgres kept every record — so `/search` returned nothing for records that demonstrably
existed, and **the registry does not reindex on start.** Fixed with a named volume:

```yaml
volumes:
  - esdata:/usr/share/elasticsearch/data
```

Note the asymmetry with postgres, which uses a **bind mount** (`./db-data`). A bind mount is not
removed by `docker compose down -v` — only `sudo rm -rf db-data/` clears it. This surprised us
once: 49 rows were still in `V_Participant` after what looked like a full reset. 47 of them were
soft-deleted (`_status=false`) probe records. Sunbird RC's `DELETE` is a soft delete.

That matters for more than tidiness: a soft-deleted row **keeps its `participant_id`**, so the
unique index still holds it and re-creating that id returns `500`. It also means a leftover
duplicate can block index creation entirely:

```
Failed Transaction creating index Participant: could not create unique index
"public_V_Participant_participant_id_sqlgIdx"
```

If you see that, the unique constraint silently does not exist and duplicate writes start
succeeding. Clear the duplicates and restart.

**Full reset:**

```bash
docker compose down -v      # also drops esdata
sudo rm -rf db-data/        # the bind mount down -v does NOT touch
```

This wipes the Keycloak realm too, so the realm import and the client-secret step must be redone.

---

## 5. Step 3 — Keycloak

`imports/realm-export.json` is the reference deployment's realm export, patched. It seeds realm
`sunbird-rc` with:

| Client | Type | Used for |
|---|---|---|
| `admin-api` | confidential, service account | The registry's own calls into Keycloak |
| `registry-frontend` | public, direct access grants | Getting a user token with username/password |

Plus, added by us: realm role `network_operator`, and user `no-user` / `no-user-password` holding
it. That removes steps 1 and 2 of `API_SPECIFICATION.md` — the role and the Network Operator user
already exist on first boot.

**One manual step cannot be automated.** The `admin-api` client secret in the realm export is not
the secret the running Keycloak will accept, so it must be regenerated and copied into `.env`
before the registry starts. Hence the two-phase bring-up in the next section.

---

## 6. Step 4 — running it

```bash
# 1. configuration
cp .env.example .env
#    fill in POSTGRES_PASSWORD, KEYCLOAK_ADMIN_PASSWORD, REGISTRY_DEFAULT_USER_PASSWORD
#    leave KEYCLOAK_SECRET blank for now

# 2. dependencies first — the registry needs a secret that does not exist yet
docker compose up -d db keycloak es

# 3. get the admin-api client secret (manual, one time per reset)
#    http://localhost:8080/auth  ->  log in as KEYCLOAK_ADMIN_USER
#    realm sunbird-rc  ->  Clients  ->  admin-api  ->  Credentials  ->  Regenerate Secret
#    copy it into .env as KEYCLOAK_SECRET=<value>

# 4. registry
docker compose up -d registry
docker compose ps

# 5. verify it is up and the schema loaded
curl -s http://localhost:8081/health
curl -s http://localhost:8081/api/docs/swagger.json \
  | grep -o '/api/v1/Participant[^"]*' | sort -u
```

That last command is the real check. If `Participant.json` failed to parse, the endpoints simply
are not there — and the registry crash-loops rather than reporting a clean error, so check
`docker compose logs registry` for a `DefinitionsManager` parse error.

### Getting a token — and the `X-Forwarded-Host` trap

```bash
curl -s -X POST \
  "http://localhost:8080/auth/realms/sunbird-rc/protocol/openid-connect/token" \
  -H "X-Forwarded-Host: keycloak:8080" \
  -H "X-Forwarded-Proto: http" \
  -d "client_id=registry-frontend" \
  -d "username=no-user" \
  -d "password=no-user-password" \
  -d "grant_type=password"
```

Those two headers are **not optional when calling from the host.** The registry validates the
token's `iss` claim against `http://keycloak:8080/auth/realms/sunbird-rc` — its own internal
view of Keycloak. A token requested from the host without the headers is issued with
`iss: http://localhost:8080/...`, which does not match, and every write returns `401` with a
token that is otherwise perfectly valid. `PROXY_ADDRESS_FORWARDING=true` on the Keycloak service
is what makes Keycloak honour the headers.

This is the single most common way to lose an hour on this stack. From inside the compose
network there is no issue — a container calling `http://keycloak:8080` gets the right `iss`
automatically. It only bites host-side callers: curl, Postman, newman.

---

## 7. The endpoints

All generated from the schema. `{osid}` is the registry-assigned system id, returned by create.

| # | Method | Path | Auth | What it does |
|---|---|---|---|---|
| 1 | `GET` | `/health` | none | Liveness, plus per-subsystem status |
| 2 | `GET` | `/api/docs/swagger.json` | none | The generated API surface — proof the schema loaded |
| 3 | `POST` | `/api/v1/Participant` | NO token | **Create.** Returns `osid` |
| 4 | `POST` | `/api/v1/Participant/search` | **public** | **Lookup.** Filter body |
| 5 | `GET` | `/api/v1/Participant/{osid}` | NO token | Read one record, straight from postgres |
| 6 | `PUT` | `/api/v1/Participant/{osid}` | NO token | **Update — a merge, see below** |
| 7 | `DELETE` | `/api/v1/Participant/{osid}` | NO token | Soft delete (`_status=false`) |
| 8 | `GET` | `/api/v1/Participant` | NO token | Records owned by the calling token (`osOwner`) |
| 9 | `POST` | `/api/v1/Participant/invite` | NO token | Create + provision a Keycloak user for it |

There is no `PATCH`. There is no generic entity API — `registry_base_apis_enable=false`.

### The four that matter

**`POST /api/v1/Participant` — onboarding.** The only way a participant enters the network.
Requires a `network_operator` or `admin` token; validates against the schema; enforces
`participant_id` uniqueness at the DB level. Everything downstream trusts this record, so this is
where correctness has to be enforced.

**`POST /api/v1/Participant/search` — the hot path.** The one endpoint that is **public**, and
the one that will carry the most traffic: it is how a consumer discovers providers. Served by
Elasticsearch.

```json
{ "filters": { "status": { "eq": "active" },
               "roles":  { "contains": "provider" },
               "domain": { "eq": "weather" } } }
```

Response shape: `{ "data": [ ... ], "totalCount": n }`. **`totalCount` reads 0** with the
Elasticsearch provider — use `data.length`. `API_SPECIFICATION.md` describes a bare array; that
is not what the running registry returns.

Being public is deliberate: discovery cannot require a credential from the network operator, or
every consumer would need onboarding before it could find anyone. Send either a real token or
**no `Authorization` header at all** — an empty `Authorization:` header is rejected, which is a
sharp edge for HTTP clients that helpfully add empty headers.

**`GET /api/v1/Participant/{osid}` — the authoritative read.** Goes to postgres, not
Elasticsearch, so it is immediately consistent. Use this to verify a write; use `/search` to
discover.

**`PUT /api/v1/Participant/{osid}` — lifecycle.** Suspension and key rotation. This is the
endpoint whose behaviour is most likely to be misread; see below.

### `PUT` is a merge, not a replace

Verified against the running registry: **`PUT` is a shallow, field-level merge** — patch
semantics under a `PUT` verb. Fields you send are overwritten; fields you omit keep their stored
values.

```json
{ "osid": "1-abc...", "status": "inactive", "record_version": 2,
  "updated_at": "2026-08-19T12:00:00Z" }
```

That suspends a participant and leaves `display_name`, `roles`, `domain`, `endpoint_url` and the
key material exactly as they were. This is stock Sunbird RC behaviour, not something configured
here. Three consequences:

- **Validation runs on the merged document**, not on the request body — which is why the system
  fields must be declared under `additionalProperties: false`.
- **Arrays are replaced wholesale**, not appended to. Sending one role replaces all roles.
- **Clearing a field means sending it explicitly** (`"domain": ""`). Omitting it preserves it.

`API_SPECIFICATION.md` describes `PUT` as a full replace that would wipe omitted fields. It does
not. Anything written against the spec's reading — expecting to blank a field by omitting it —
will quietly not do that.

### `DELETE` is a soft delete

The row stays with `_status=false` and **keeps its `participant_id`**. The id is therefore not
reusable: re-creating it hits the unique index and returns `500`. Plan participant ids
accordingly, and do not treat a delete as a way to free a name.

---

## 8. The end-to-end flow

```
                          ┌──────────────┐
                          │   Keycloak   │  realm sunbird-rc
                          │              │  role: network_operator
                          └──────┬───────┘
                    (1) token           (2) validate iss + roles
                          │                        ▲
                          ▼                        │
   ┌──────────────┐  (3) POST /Participant   ┌─────┴──────┐   (4) index
   │   Network    ├─────────────────────────►│  Registry  ├──────────────► Elasticsearch
   │   Operator   │◄─────────────────────────┤            │                     ▲
   └──────────────┘        osid              └─────┬──────┘                     │
                                                   │ writes                     │ (5) POST /search
                                                   ▼                            │
                                              Postgres                    ┌─────┴──────┐
                                            (authoritative)               │  Consumer  │
                                                                          │   / ONIX   │
                                                                          └─────┬──────┘
                                                    (6) endpoint_url + key      │
                                                    ◄───────────────────────────┘
```

**Onboarding.** The Network Operator gets a token from Keycloak (1) and posts a participant
record (3). The registry validates the token's issuer and checks `realm_access.roles` against
`_osConfig.roles` (2), validates the body against the schema, writes to postgres, and indexes to
Elasticsearch (4). It returns an `osid` — the handle for every later read, update and delete.

**Discovery.** A consumer, or ONIX on its behalf, posts a filter to `/search` (5) with no
credential. It gets back matching participants including `endpoint_url` and
`signing_public_key` (6). That is the whole point of the registry: turn "an active weather
provider" into an address and a key.

**Trust.** The consumer sends its request to `endpoint_url`. The provider signs its response with
the private half of `signing_public_key`; the consumer verifies with the public half it just
fetched. The registry never holds a private key and never proxies traffic — it only distributes
public keys and addresses. That is why `signing_public_key` is required and why key validity
windows exist.

**Lifecycle.** Suspension is `PUT` with `status: "inactive"` and a bumped `record_version` — the
record stays queryable and auditable, and a `status: eq active` search stops returning it.
Removal is `DELETE`, a soft delete. Key rotation is a `PUT` replacing `signing_public_key` and
its validity window; with the flat schema this overwrites rather than overlapping (see §3).

### Consistency, stated once

Two stores, two guarantees:

- **Postgres is authoritative and immediately consistent.** `GET /{osid}` reads it.
- **Elasticsearch is eventually consistent — roughly a one-second refresh.** `/search` reads it.

A search fired immediately after a write can miss it. The Postman collection forces
`POST {{es_url}}/_refresh` before searching to make the tests deterministic; that is a dev-only
trick, not something a client should rely on. Real clients should verify writes through
`GET /{osid}` and treat search as a discovery index, not a read-after-write store.

---

## 9. Step 5 — testing

Two layers, on purpose: one you can run in 30 seconds, one that covers everything.

### `smoke-test.sh` — is the stack alive

Token → create → search → suspend → assert. Prints `PASS` and the cleanup command, or exits
non-zero on the first step that misbehaves. Needs `python3` on the host to read JSON. This is
the "did my change break the stack" check.

### `postman/OAN-Registry.postman_collection.json` — the flow test

36 requests, 70 assertions, self-cleaning so it can be run repeatedly.

```bash
npx newman run postman/OAN-Registry.postman_collection.json
```

**Last verified run: 36 requests, 70 assertions, 0 failures.**

Order, which is the flow in §8 made executable:

1. Health check (stamps a per-run `run_id`) and the swagger surface
2. Network Operator token — asserts the role *and* the `iss` claim
3. Create the Network Operator's own record, then a Provider (saves `provider_osid`)
4. Five search shapes: by id, all active providers, active in one domain, inactive (none yet),
   and a no-match returning an empty list
5. Read by osid, and list by token (`osOwner`)
6. Suspend via partial `PUT`, confirm by osid, then confirm the inactive search now finds it
7. Reactivate via full-body `PUT`, confirm
8. Invite
9. **Ten rejection cases:** no token, wrong issuer, missing required field, bad enum value,
   undeclared field (typo), duplicate id, empty `Authorization` header on search, `GET` with no
   token, unknown osid, invite with no token
10. Delete, confirm `404` by osid, confirm it is gone from search, clean up the rest

The rejection cases are half the value. They are what proves the schema and `_osConfig` are
actually enforced rather than merely written down.

`run_id` exists because a deleted record keeps its `participant_id` (§7), so every
`participant_id` in the collection is stamped with the run to keep it re-runnable.

Where observed behaviour differs from `API_SPECIFICATION.md`, the request description says so.

### The bug the collection found: JSESSIONID is bearer-equivalent

Three "must fail without a token" tests passed in curl but returned `200` in newman. Cause,
confirmed by capturing headers with an echo server:

**The registry issues a `JSESSIONID` cookie on the first token-authenticated call, and afterwards
accepts that cookie *instead of* a bearer token.** `POST` and `DELETE` on Participant both
succeed with only the cookie and no `Authorization` header.

So any client with a cookie jar — Postman, newman, a browser — stays authenticated after one
token call, which silently defeats every no-token test. Fixed by disabling cookies collection-wide
(`protocolProfileBehavior: { disableCookies: true }`), which is also how a real client such as
ONIX behaves.

This is worth raising before the registry is exposed anywhere beyond dev: a leaked session cookie
is as good as a leaked token, and it does not expire on the same schedule.

---

## 10. Everything verified, in one place

Behaviour of the running stack, each item established by test rather than by reading docs.

| Area | Behaviour |
|---|---|
| Auth | Writes need `network_operator` or `admin`; `/search` is public; an **empty** `Authorization` header is rejected |
| Issuer | Host-side tokens need `X-Forwarded-Host: keycloak:8080` + `X-Forwarded-Proto: http`, else `401` |
| Session | `JSESSIONID` is accepted in place of a bearer token |
| `PUT` | Shallow field-level merge; validates the merged document; arrays replaced wholesale |
| `DELETE` | Soft delete, `_status=false`, `participant_id` **not** reusable |
| Duplicates | `500` with a postgres `duplicate key` message, not a clean `400` |
| Unknown fields | `400` — `additionalProperties: false`; system fields must be declared for `PUT` to work |
| `/search` shape | `{ data, totalCount }`; **`totalCount` is 0** — use `data.length` |
| `/search` latency | ~1s Elasticsearch refresh; `GET /{osid}` is immediate |
| osid | One per record, because the schema is flat |
| Schema reload | Boot-time only — `docker compose restart registry` |
| Persistence | `esdata` is a named volume (`down -v` clears it); `db-data/` is a bind mount (`down -v` does **not**) |

### Divergences from `API_SPECIFICATION.md`

Three, all confirmed:

1. `PUT` merges; the spec describes a full replace.
2. `/search` returns `{ data, totalCount }`, not a bare array — and `totalCount` is unusable.
3. A duplicate `participant_id` returns `500`, not `400`.

Steps 1–2 of the spec (create the realm role, create the Network Operator user) are pre-applied
by `imports/realm-export.json`.

---

## 11. Known limits and what comes next

**Dev-only, must change before anything shared:**

- Dev credentials in `imports/realm-export.json` — drop the `no-user` block, create users in the
  admin console
- `xpack.security.enabled=false` on Elasticsearch, which is reachable on 9200
- Postgres and Elasticsearch ports published to the host
- HTTP throughout, no TLS
- The `JSESSIONID`-as-token behaviour in §9

**Open design questions:**

- **Key rotation with overlap.** The flat schema holds one key. Overlapping old/new keys needs
  either `signing_public_key_next` fields or nested key objects and their child osids.
- **`record_version` is not enforced.** Nothing rejects a stale version — no optimistic locking.
  If concurrent Network Operator writes become real, this needs a check.
- **`totalCount` is broken**, so search cannot paginate meaningfully yet.
- **Duplicate id returns `500`.** A client cannot cleanly distinguish "already exists" from a
  real server error.

**Next:**

- ONIX as a sibling compose under `network-layer/`, consuming `/search` for resolution
- Publish/discover flows — not designed yet, which is why nothing here claims to implement them
- CI: the newman run is the obvious gate for schema changes

---

## 12. Quick reference

```bash
# bring up
cp .env.example .env && $EDITOR .env
docker compose up -d db keycloak es
# regenerate admin-api secret in the Keycloak console -> KEYCLOAK_SECRET in .env
docker compose up -d registry

# is it alive
curl -s http://localhost:8081/health
curl -s http://localhost:8081/api/docs/swagger.json | grep -o '/api/v1/Participant[^"]*' | sort -u

# token (the forwarded headers are required from the host)
TOKEN=$(curl -s -X POST \
  "http://localhost:8080/auth/realms/sunbird-rc/protocol/openid-connect/token" \
  -H "X-Forwarded-Host: keycloak:8080" -H "X-Forwarded-Proto: http" \
  -d "client_id=registry-frontend" -d "username=no-user" \
  -d "password=no-user-password" -d "grant_type=password" \
  | python3 -c 'import sys,json; print(json.load(sys.stdin)["access_token"])')

# search (public)
curl -s -X POST http://localhost:8081/api/v1/Participant/search \
  -H 'Content-Type: application/json' \
  -d '{"filters":{"status":{"eq":"active"},"roles":{"contains":"provider"}}}'

# test
./smoke-test.sh
npx newman run postman/OAN-Registry.postman_collection.json

# after a schema change
docker compose restart registry

# full reset
docker compose down -v && sudo rm -rf db-data/
```
