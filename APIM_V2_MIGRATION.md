# Moving AIFAPIM to API Management v2

Plan for moving the AIFAPIM gateways from API Management Classic (Developer
tier) to **Standard v2 behind Azure Front Door Premium**, as two new
gateway-only stacks, `aifapimv2` (prod) and `aifapimv2-dev`, built beside the
Classic ones:

- The gateway is Standard v2, with outbound traffic through our virtual network
  to private endpoints on the existing Foundry accounts.
- The gateway has public network access **Disabled**. The only way in is Front
  Door, over an approved Private Link connection, so no public IP resource of
  ours is needed (a BNL policy denies them).
- The host name `aifapimv2(-dev).nsls2.bnl.gov` and its certificate live on
  Front Door. A WAF policy at the edge allows only the listed client
  addresses.

An earlier plan had a second stage, Premium v2 behind an Application Gateway,
which needs a public IP resource and an exemption from that policy. Front Door
gives the network-level inbound control without either, so that stage is
dropped.

This file is the master plan (design, costs, phases, results). The settings,
key tooling, scripts and the step-by-step deployment are in
`docs/apim-v2-migration.md` of
[aifapim-config](https://github.com/NSLS2/aifapim-config), the companion repo.

Last updated 2026-11-27. The checkboxes in "Phases" are ticked in this pull
request as work lands.

## Status

| Piece | State |
| --- | --- |
| Design, names | Decided (see "Decisions") |
| Gateway certificates (all four) | Re-issued RSA 4096 with the SSL.com intermediate, in Key Vault |
| Certificate renewal playbook | NSLS2/ansible pull request 5178 (open); the `acme_certificates` role builds the PFX with the intermediates |
| Key Vault firewall template | Deployed |
| Dev network (`aifapimv2-network.bicep`) | Deployed, with the `int` subnet |
| Dev gateway (`aifapimv2.bicep`, Standard v2) | Deployed 2026-11-26, public access Disabled; model smoke test passes through Front Door |
| Front Door (`modules/front-door.bicep`) | Dev: Premium profile, endpoint, WAF, Private Link approved, custom domain `aifapimv2-dev.nsls2.bnl.gov` validated and serving the RSA certificate chain |
| DNS records | Not yet: the CNAME to the Front Door endpoint is to be requested; test on the endpoint's `azurefd.net` name |
| Event Hub and security events (`modules/event-hub.bicep`, `modules/security-events.bicep`) | Dev: deployed 2026-11-27; one JSON event per request from the service-level policy, over a private endpoint, no prompt text. Hub messages match gateway requests by count; the content of an event is not read yet |
| Request body log | Dev: deployed and working 2026-11-27 (infrastructure 7 min 39 s, immutability policy created, unlocked; function code published). Byte-for-byte storage of binary and large bodies is not verified on v2 (see the checklist) |
| Prod stack (`aifapimv2`) | Not started |
| Agent client in the logs and token metrics | Merged from `main`; not tried on v2 |

## Why, and what Microsoft gives us

There is no in-place upgrade from Classic to v2, so each v2 instance is a new
service and the configuration is replicated. Reasons to move:

- Classic Developer has no SLA and one unit. The Classic advisory response
  (`MZK9-GH0`) left "move off Classic to a v2 tier" as its last open item.
- The Anthropic logging gaps (completion tokens always 0, empty model name for
  streaming, missing prompts) may be fixed on v2. Microsoft lists the Anthropic
  Messages API as supported in the v2 tiers. This is to be measured in dev.
- Standard v2 has an SLA and several units (up to 10). Zone redundancy for
  Standard v2 was announced on 2026-08-27: `zoneRedundant: true` on the
  service, from API version 2025-03-01-preview (Microsoft's reliability page
  has not caught up). It can only be chosen when the instance is created, and
  the create fails if the region cannot place it. One unit spreads over two
  zones. Prod sets it; dev was created without it. Both stacks use the newest
  preview API version for the service resource, so they differ only in this
  property. In prod the request log storage accounts are `Standard_ZRS`; the
  Flex plan is not zone redundant (it would keep two instances always running).
  **ZRS has no Archive tier**, so the prod blobs move Hot to Cold at 7 days and
  stay there (the template adds the Archive step only on LRS, GRS and RA-GRS).
  Chosen 2026-11-27 over LRS with Archive (zone redundancy was the point of the
  prod design). Cost, eastus retail prices that day: Cold ZRS $0.004 per GB-month,
  Archive LRS $0.00099. Classic prod's body log grew from 2.4 GB (1 November) to
  266 GB (26 November), about 10.5 GB a day or 3.9 TB a year, kept for ever. At
  that rate Cold ZRS costs about $15 a month after one year and $77 after five,
  against $4 and $19 in Archive: about $1,750 more over five years. Cold is also
  readable at once, where Archive needs hours of rehydration.

What v2 does not have (Microsoft, 2026-11): multi-region, backup and restore,
Git configuration, direct management API access, cipher configuration, the
service-wide CA certificate list, built-in analytics, resource move. None of
these is used by this repository, to be confirmed by a search before dev.

## Design

```text
Callers (Hermes WAF, NAT pool, Anthropic, others on the allow-list)
        |  HTTPS 443, aifapimv2(-dev).nsls2.bnl.gov (CNAME to Front Door)
        v
Front Door Premium  (certificate from Key Vault, WAF: allow-list on SocketAddr)
        |  Private Link, approved by hand; no public address on the gateway
        v
API Management Standard v2 (1 unit, public network access Disabled)
        |  outbound through subnet `int` (delegated, NSG), managed identity
        v
Private endpoints in subnet `pe` -> existing Foundry accounts (East US, East US 2)
```

| | aifapimv2 (prod) | aifapimv2-dev |
| --- | --- | --- |
| Resource group | `rg-aifapimv2-prod-1` | `rg-aifapimv2-dev-1` |
| Host name | `aifapimv2.nsls2.bnl.gov` | `aifapimv2-dev.nsls2.bnl.gov` |
| Network | `net-aifapimv2-prod`, 10.10.0.0/16 | `net-aifapimv2-dev`, 10.11.0.0/16 |
| Subnets in use | `int` .4/24, `pe` .2/24 | same offsets |
| Backends | Foundry accounts in `rg-aif-apim-prod-1` | those in `rg-aif-apim-dev-1` |

- **Gateway only.** Foundry accounts, model deployments and their quota stay
  where they are. Quota in East US and East US 2 is largely allocated already,
  so duplicating the deployments is not an option. The v2 gateway reaches them
  through its own private endpoints and private DNS zones (two endpoints to one
  account cannot share a zone). The accounts' diagnostics stay in the Classic
  stack's Log Analytics until Classic is removed. Each v2 stack has its own Log
  Analytics workspace so that both can run side by side.
- **Outbound through our network.** Standard v2 integrates with a delegated
  subnet (`Microsoft.Web/serverFarms`, at least /27, one instance only) with an
  NSG that allows outbound 443 to `AzureKeyVault`. Backends in the network,
  including private endpoints, are reachable.
- **Inbound only through Front Door.** With `publicNetworkAccess` Disabled the
  platform refuses direct calls to the gateway. Front Door requests a Private
  Link connection on the gateway, which is approved by hand once. Front Door
  Premium is needed for Private Link, and it needs no public IP resource of
  ours: the "Deny public IPs" policy does not block it or Standard v2.
- **The WAF allow-list uses `SocketAddr`.** `RemoteAddr` follows
  `X-Forwarded-For`, which a client can forge. `SocketAddr` is the address of
  the connection that reached Front Door. A WAF rule refuses overlapping
  entries, so bare addresses inside a listed CIDR are dropped (`wafAllowList`
  in `aifapimv2.bicep`). Its conversions use `?:`, because ARM's `and()` and
  `or()` do not short-circuit.
- **One client address check in every policy.** Every API policy sets
  `clientAddress` first: the connecting address or, only when that is private
  (10/8, 172.16/12, 192.168/16, 100.64/10: how Front Door's Private Link
  arrives), the `X-Azure-SocketIP` header, which Front Door overwrites. The
  global allow-list, the product checks and the `X-Forwarded-For` metric
  dimension read it. It gives the same answer with public access Enabled or
  Disabled, so reopening the gateway (as the bootstrap does) never lets a
  forged header through, and a failed policy deployment fails closed.
  `X-Forwarded-For` and `X-Azure-ClientIP` are forgeable and are not trusted.
- **Timeouts.** Front Door waits up to 240 seconds (its maximum) for the first
  byte from the gateway and for each pause in a body, and the gateway's
  `backendTimeoutSeconds` is 240. Measured on dev: a non-streamed call with no
  byte for 230 seconds fails with 500 and an HTML page ("The request timed
  out"), not Front Door's 503. Front Door logged origin status 500 with
  `errorInfo` NoError, and the gateway logged `ClientConnectionFailure` at
  230.2 seconds with response code 0 and no retry: the connection in front of
  the gateway was closed, so the platform enforces 230 seconds, not the policy.
  A streamed call that keeps sending bytes is not affected (one survived 249
  seconds). **Decision: leave `backendTimeoutSeconds` at 240.** A value below
  230 would only make the gateway fail first, and the policy retries every 5xx,
  so the client would still be cut at 230 seconds with the same HTML page.
  Clients must stream any call that can take longer than 230 seconds. Not
  checked: what Classic does for the same call.
- **Host name and certificate on Front Door.** The gateway keeps no custom
  domain (`apimGatewayHostName` stays empty). Front Door reads the certificate
  from Key Vault with its own identity (Key Vault Secrets User), and accepts
  only RSA certificates with their intermediates. The gateway identity gets no
  vault role (`grantGatewayVaultAccess` is false); a custom domain on the
  gateway itself would need it set in a deployment before the one that sets
  `apimGatewayHostName`. Front Door's endpoint is named
  like the gateway (`apim-dev-<unique>`), because `test-models.py` expects the
  host name to contain `dev`.
- **The gateway is deployed in steps** (the companion runbook has the commands).
  APIM refuses to disable public access before a private endpoint connection
  exists, and the Front Door identity needs its Key Vault role before it can
  read the certificate. So: bootstrap with public access Enabled and no host
  name, approve the Front Door connection, close the public address, then set
  `frontDoorHostName`. A `.bicepparam` file cannot be combined with other
  `--parameters`, so the steps mean editing the file between deployments.
- **No hub peering.** The networks stay stand-alone.
- **Network first.** The network (`aifapimv2-network.bicep`) is deployed on its
  own, then the gateway (`aifapimv2.bicep`), which includes Front Door.
- **Unused subnets.** The network template still creates two subnets reserved
  for the dropped Premium v2 design: `apim` and `agw`, and the vault firewall
  holds an `agw` rule. They carry nothing and are to be removed with the
  template change (phase 1).

## What changes in the code (Classic to Standard v2)

| Area | Today (Classic) | On Standard v2 |
| --- | --- | --- |
| Network | Injected in External mode, NSG and route table in `network.bicep` | New `aifapimv2-network.bicep`; outbound integration subnet `int` |
| Ingress | The gateway's own public address | Front Door Premium over Private Link; `modules/front-door.bicep` |
| API version | `2023-03-01-preview` | `2024-05-01` or later for v2 |
| TLS ciphers | `customProperties` in `api-management-private.bicep` | Not available on the gateway; Front Door allows TLS 1.2 and 1.3 only |
| CA certificates | `certificates` list (InCommon) | Not used, and removed from Classic too (separate pull request): the live gateways serve an SSL.com chain from the Key Vault certificate, and nothing uses a client certificate |
| Inbound lock | `gatewayInboundSources` on the APIM subnet NSG (dev) | The WAF allow-list at Front Door, and the `clientAddress` check in the policies |
| Caller address | `ip-filter` sees the caller | `clientAddress` variable: the connecting address, or `X-Azure-SocketIP` when the connection is Front Door's Private Link |
| Custom domain | APIM custom host name | On Front Door, not on APIM |
| Gateway to storage, Event Hub | Trusted-service bypass or private endpoint | Private endpoints (trusted-service access for the gateway data plane ended March 2026) |
| Deploy ordering | One-at-a-time writes (Developer "ServiceLocked race") | Kept first, relax after dev shows it is not needed |
| Subscriptions | People, services, beamlines, catalog poller | Recreated with the same key values (companion repo); the built-in all-access subscription `master` is suspended by hand |
| Which tool called | A policy variable `agentClient` (the `X-Agent-Client` header if it is one of `opencode`, `opencode2`, `claude`, `codex`, else matched from `User-Agent`, else `other`), logged with `User-Agent` and added to the usage trace and token metrics. Statistics only: a client sets both headers itself | Same files, merged from `main`; the headers are to be checked through Front Door |
| Dashboard | Grafana dashboard with cost panels | The same dashboard: its Environment variable gains the v2 workspaces (Dev v2 now, Prod v2 when that stack exists) and a v2 edge row. The cost panels are empty for v2 (shared Foundry accounts, billed to Classic). The Classic options go at cutover |

## Usage and cost

Measured on Classic prod (`apim-ol3ingt73lvcm`, Developer, one unit) on
2026-11-26, Azure Monitor metrics and Cost Management.

| 30 days to | Requests | Busiest day |
| --- | --- | --- |
| 2026-09-25 | 306,000 | 14,700 |
| 2026-10-25 | 372,000 | 20,300 |
| 2026-11-25 | 615,000 | 50,700 |

- 95th percentile minute: 41 requests; 99th: 94; busiest minute 3,299
  (23:42 EDT on 28 Oct, 03:42 UTC on 29 Oct), probably one script. Average
  response time 4 to 7 seconds, about 98% of it waiting for the models. The
  Classic unit averaged 20 to 43% capacity.
- Today APIM costs about $48 a month per environment. Prod's October total was
  about $38.7k, almost all Foundry models and the Claude Marketplace charge.
  Log Analytics in prod rose to about $350 for November so far: to explain.

List prices, East US, 730 hours a month:

| Item | Per month | Notes |
| --- | --- | --- |
| Developer (Classic, today) | $48 | No SLA |
| Basic v2 | $150 | No network integration: cannot reach the private endpoints |
| **Standard v2** | **$700** per unit | 50 million calls included, so no call charge at today's volume |
| Front Door Premium | fixed fee plus usage | Needed for Private Link; the fixed fee and the request and transfer charges are to be read from Cost Management after dev has run |
| Premium v2 (not used) | $2,800 | With an Application Gateway, about $2,970 a month per stack |

- **Planned design:** about $1,030 a month per stack (Standard v2 plus Front
  Door Premium), about $2,060 for dev and prod together, plus about $7 for each
  private endpoint. That is about $1,960 more than today (roughly 5% of
  October's prod spend). A second Standard v2 unit is expected to cost about
  $500 (the secondary-unit rate, $0.68493 an hour), not confirmed. One unit is
  expected to be enough, to be shown in dev (phase 3).
- **Dropped design:** Premium v2 behind an Application Gateway, about $2,970 a
  month per stack, about $5,940 for both.

## Public IP policy

A BNL management-group policy ("Deny public IPs", `Not allowed resource types`)
blocks `Microsoft.Network/publicIPAddresses`; the first Classic dev deployment
failed on it (a NAT gateway), see `AGENTS.md`.

- **The v2 design creates no public IP resource.** The Standard v2 gateway has
  no public address of ours (and public access is Disabled), and Front Door is a
  Microsoft-managed edge. The dev stack deployed under the policy, so no
  exemption is needed.
- **Why not Premium v2 with an Application Gateway.** That needs a public IP
  resource, so an exemption from the cloud administrators, and costs about
  $2,970 a month per stack. Private-only designs do not serve the callers:
  Hermes and the Anthropic addresses connect from outside, and the AIFAPIM
  networks are not connected to the BNL network. Front Door gives the same
  inbound control without the exemption.

## Public access and threat model

Decided 2026-11-28. Each stack serves its Front Door endpoint and four names, so
a cutover is a DNS change and a rollback is the reverse:

| Stack | Names |
| --- | --- |
| prod | `aifapimv2`, `aifapim`, `hermes`, `aigw` |
| dev | `aifapimv2-dev`, `aifapim-dev`, `hermes-dev`, `aigw-dev` |

`aigw` is the new public name that replaces `hermes` (which is now the name of
an AI product). `hermes` stays for a notice period, then goes. Each name has its
own RSA 4096 certificate (the ansible certificates playbook) and its own Front
Door secret, domain and secret-scoped Key Vault role. No SAN or wildcard
certificate: Hermes' current `*.nsls2.bnl.gov` certificate stays on its WAF.

**Access.** Prod is public with a key: no address allow-list in the WAF or in the
gateway. Dev is locked to the NSLS-II NAT pool. The products
`nsls2aifapim-services-internal` and `nsls2aifapim-services-agents` are locked to
the NAT pool on both stacks (a check in the product policy). The template
creates the WAF allow-list rule and the global gateway address check only when
`allowedClientIps` is not empty.

**Edge rules for the public names**, each starting on Log and moving to Block
after a clean week in the WAF log: a key header is required (except on the
health path), only the known API paths and the GET and POST methods are allowed,
and a rate limit per address, set from the Hermes traffic on Classic (twice to
three times the peak; Microsoft advises a high threshold and a 5-minute window).
The managed rules exclude the four key headers. Request body inspection stays
off: a prompt with code, SQL or a shell command looks like an attack to the
managed rules.

**Accepted risks.** A valid key works from anywhere on prod from deploy day, with
the key, the WAF and the product locks as the controls. A key revoked on Classic
stays valid on v2 until the next `copy-keys-to-v2.py` run, so the weekly run
needs `--prune`. The rules of Hermes' current WAF (sigsci) are not carried over.
Answers have no write-once copy (see the follow-up page).

### OWASP Top 10 for LLM applications (2025)

| Risk | Where it is handled |
| --- | --- |
| LLM01 Prompt injection | Not at the gateway: the application or agent that holds the tools. A pattern filter here blocks real work. A Content Safety study is open. |
| LLM02 Sensitive information disclosure | Part: the gateway logs prompts, restricts who reads the logs (Grafana limited to its tables), and an offline secret scan is planned. Which data people send is policy and training. |
| LLM03 Supply chain | Hosted models only; a model joins the catalog by approval. |
| LLM04 Data and model poisoning | Does not apply: no training or fine-tuning here. |
| LLM05 Improper output handling | The application that uses the answer. |
| LLM06 Excessive agency | The agent and its tools, not the gateway. |
| LLM07 System prompt leakage | Prompts are stored write-once with restricted access; the gateway adds none of its own. |
| LLM08 Vector and embedding weaknesses | Not at the gateway; embeddings are proxied as they come. |
| LLM09 Misinformation | The user and the application. |
| LLM10 Unbounded consumption | The gateway: token limit per key, image and audio request limits, the Front Door rate limit, per-key anomaly alerts (planned). |

The follow-up work is in `aifapim-config/docs/llm-security-follow-up.md`.

## Certificates

- All four gateway certificates (`aifapim`, `aifapim-dev`, `aifapimv2`,
  `aifapimv2-dev`) are RSA 4096 with the `SSL.com TLS Issuing RSA CA R1`
  intermediate in the PFX, in the Key Vault `acme-tls-certificates`. Front Door
  refuses EC certificates and needs the intermediates, so the earlier ECDSA
  P-256 certificates were replaced. Valid to 2027-06-13 for the dev v2 name
  (renew from the middle of May 2027).
- Renewal is `aifapim_gateway_certificates.yml` in NSLS2/ansible (pull request
  5178, open). It reads the expiry from Key Vault, issues when under 28 days
  remain, imports with `az` as the calling user, and removes its temporary
  directory. The `acme_certificates` role builds the PFX from the leaf plus
  `other_certificates`.
- Checked on dev: the custom domain on Front Door serves the RSA 4096 leaf plus
  the issuing CA, verification succeeds for the host name, over TLS 1.3. Classic
  dev serves the new certificate. Classic prod still serves the old ECDSA one: it
  picks up the new version on its own schedule, or by "Sync certificates" in the
  portal (about 20 minutes of outage on the Developer tier), to be done at a
  quiet time.
- An alert on the expiry of the certificate each gateway serves belongs in
  phase 3: for Front Door, the Resource Health event `CertificateExpiresSoon`
  (`alert-rules` skill).

## Key Vault firewall

The vault denies by default, allows trusted Microsoft services, the NAT pool,
and the subnets listed in `azure/infra-certificates` of NSLS2/bicep: the two
Classic `apim` subnets and, since 2026-11-26, the dev `agw` subnet.

- Front Door reads the certificate from Key Vault as a trusted service with its
  profile's system-assigned identity, so it needs no subnet rule, only the Key
  Vault Secrets User role, granted after the profile exists.
- The dev `agw` rule was added for the dropped Application Gateway design and is
  unused. Remove it with the `agw` subnet.
- The v2 gateway itself reads no certificate.

## Decisions

- Tier: Standard v2, for prod and dev alike, behind Front Door Premium over
  Private Link. Reason: Premium v2 injection needs an Application Gateway with a
  public IP resource, which a BNL policy denies; Standard v2 and Front Door do
  not need one, and cost about a third as much.
- The gateway's public network access is Disabled in the running state;
  bootstrap needs it Enabled for one deployment.
- Stacks: gateway only, reusing the Foundry accounts; names as in the table.
- Host name and certificate on Front Door, RSA only. Four names per stack, one
  certificate each, public with a key on prod (see "Public access and threat
  model").
- A separate Log Analytics workspace per stack, and a v2 Grafana dashboard
  without cost panels; one dashboard and the cost ingest move when Classic is
  gone. The request body log is assumed to get its own storage and workspace
  per stack.
- No peering to the BNL hub; no DNS records yet (Azure-generated names first).
- This template supports v2 only. Classic stays at the last `main` commit
  before this change until it is removed; an urgent Classic fix is made from a
  branch of that commit.
- aifapim is merged first: the companion settings load
  `../aifapim/aifapimv2*.bicep`.
- The built-in all-access subscription is turned off on both v2 instances, by
  hand (a template write fails with "Can't modify global subscription").
- Request tracing is turned off on every subscription the key tooling makes
  (`apim-subscriptions.bicep` in the companion repository sets
  `allowTracing: false`); the gateway template creates no subscription.

## Phases

Dev always goes before prod.

### Phase 0: prerequisites

- [x] Tier, design and names decided
- [x] Certificates issued and in Key Vault (RSA 4096 with the intermediate)
- [x] Certificate renewal playbook written (NSLS2/ansible pull request 5178,
  open)
- [x] Key Vault firewall template deployed (NSLS2/bicep)
- [x] Public IP policy: Standard v2 and Front Door deploy under it (dev,
  2026-11-26); no exemption needed
- [ ] Explain the November Log Analytics cost in prod
- [ ] Search the repository for Classic-only features (see "Why")
- [x] Decided: copy the existing key values to v2, so users change only the
  host name
- [ ] Decide: Hermes origin for `aifapimv2` (the custom host name directly)
- [ ] DNS records for both host names (a CNAME to the Front Door endpoint; dev
  first)

### Phase 1: templates and settings

- [x] `aifapimv2-network.bicep` and `aifapimv2-dev-network.bicepparam`, with the
  integration subnet `int`
- [x] `aifapimv2.bicep`: APIM Standard v2 with the integration subnet, private
  endpoints and DNS zones for the existing Foundry accounts, role assignments,
  logging (policies, APIs and products rendered as in `aifapim.bicep`)
- [x] `modules/front-door.bicep`: Premium profile, endpoint, WAF, Private Link,
  custom domain and certificate
- [x] One `clientAddress` check in every API policy (global, product and metric
  dimension)
- [x] API version 2024-05-01 in `modules/api.bicep`. Classic's `aifapim.bicep`
  builds with it too; run a what-if on Classic dev before any Classic redeploy
- [x] Settings for the dev gateway (`aifapimv2-dev.bicepparam`)
- [x] Agent client tracking merged from `main`
- [x] Request body log in the v2 template (its own storage and workspace per
  stack; its storage private endpoint is in `pe`, the function in a `reqlog`
  subnet that the template adds in 10.x.3.0/24). First deployment with
  `requestLogManageImmutabilityPolicy = true` (a new account has no policy),
  then `false`: a rewrite of the policy hung a Classic deployment for 3 h 26 min.
  Dev: the first deployment took 7 min 39 s and created the policy (146000 days,
  unlocked); the setting is now false. Checked 2026-11-27 from the control plane
  (no host reaches the private blob or Log Analytics names): every POST after the
  deploy has a stored body (52 posts, 0 not loaded; 54 of 54 blob writes 201; no
  incomplete request), App Insights, the usage trace and the Event Hub still
  receive data. Not verified on v2: `devcheck binary` and `large` (byte-for-byte
  storage) and `devcheck latency` could not run, because the BNL resolver answers
  NXDOMAIN for `stllmreqrckovrtmvdr3y.blob.core.windows.net` and sends
  `api.loganalytics.azure.com` to 10.8.64.7, an address that is not ours. The
  loader and the policy fragment are the Classic ones, where they were checked.
  Run them from a host inside the v2 VNet or after BNL DNS resolves the private
  zones, with `requestLogReaderIps = ['130.199.137.0/28']` for the run
- [x] Event Hub with a private endpoint in `pe` and a security event per
  request (`SecurityEvent_Fragment.xml`, written by the service-level policy
  `Global_Policy.xml`: after every response and in on-error, so refused
  requests are in it), a consumer group `alloy-loki` for the log reader (plan:
  pull into Loki with Alloy), trusted-service access on (APIM's management
  plane tests the logger connection from outside the VNet and is refused
  without it, tried on dev 2026-11-27), reachable from outside the VNet only
  from `eventHubAllowedIps` (dev: the NAT pool)
- [x] WAF managed rules in the Front Door template: default rule set 2.2 in
  Prevention, bot manager 1.1, HTTP DDoS 1.0 (its rules log by default; the rule
  set takes no action of its own: the API refuses an action for it); request
  body check by `wafInspectRequestBody` (dev: off, see Phase 3)
- [ ] Settings for the prod gateway (network 10.10.0.0/16)
- [x] Key copy script (same key values) and the scripts that name the APIM
  resource (companion), v2 entries in `beamline-keys.py`, `test-models.py` and
  `request-log/devcheck.py`. Run on dev 2026-11-27: the preview found 2 creates
  (the two person keys) and one orphan (`svc-v2-smoke`, kept); `--apply` created
  both, active, on the product, with the keys read back equal. Creating works on
  v2; changing an existing key (PATCH, an expiry cleared with null) is untried.
  Copilot's round on the script (scope string, failed read then `--prune`, expiry)
  is fixed and tested
- [x] `GET /catalog/chat` (the chat model list, the old `GET /catalog` marked
  deprecated and returning the same body): in `aifapim` on `main` through
  `add_catalog_chat` and on this branch; `test-models.py` checks both paths agree.
  Callers (the ansible catalog poller) move over the parallel month; remove
  `/catalog` once the gateway log shows no `getCatalog` call
- [ ] Drop the `apim` and `agw` subnets and their NSGs from the network
  template, and the vault's `agw` rule
- [ ] Split the Foundry accounts and models out of `aifapim.bicep` (it owns
  them; v2 only copies the names), before Classic is removed

### Phase 2: deploy dev

- [x] Create `rg-aifapimv2-dev-1` and deploy the network (2026-11-26), then
  again with the `int` subnet
- [x] Deploy the gateway in steps (bootstrap, approve Front Door, close public
  access, custom domain on Front Door); done 2026-11-26 and 2026-11-27
- [x] Suspend the built-in `master` subscription by hand
- [ ] CanNotDelete lock on the resource group

### Phase 3: test dev

Done:

- [x] Smoke test through Front Door (`test-models.py`), 2026-11-27 09:3x EST:
  48 pass, 2 warn (`claude-fable-5-2*` return empty replies, as on Classic
  prod), 0 fail. Only the router catalog check failed: the deployed gateway
  still served the old 8-model catalog. After the dev deploy of the regenerated
  catalog (12 models) the same test passed everything on 2026-11-27:
  48 pass, 2 warn, 0 fail, and the router, image, embedding and transcription
  catalog checks pass. The first run of this test through `test-v2-dev` failed
  18 models with 404 because it took the model list of the v2 settings, which
  has names only, and tested Claude and FLUX models as OpenAI; it now reads
  `aifapim-dev.bicepparam`
- [x] 6,600 calls to `GET /catalog` at 55 requests a second for 120 seconds
  (`afd-burst-test.py`) all returned 200: latency p50 32 ms, p95 99 ms, max
  1.3 s. The gateway metrics for the window: CPU at most 4% (most minutes 1%),
  memory about 0 (the metric did not move, as before), `Requests` total 6,600.
  `/catalog` is answered by the gateway with no model call, so this is a floor,
  not the load of real traffic
- [x] A non-streamed call over 230 seconds fails with 500 and HTML (see
  "Timeouts")
- [x] Token metering equals Classic dev (the same smoke test, read from
  `AppMetrics` and `ApiManagementGatewayLlmLog` on 2026-11-27): the same 15
  token and count metrics, and the same dimension keys on every token metric,
  `Agent Client` and `Subscription Name` among them, so nothing is dropped by
  the limit of 5 custom dimensions. Anthropic completion tokens are recorded
  (322 on both) and every Anthropic call in the LLM log has its model name and
  completion tokens, so the old logging gaps do not show on either gateway.
  Not checked: `Agent Client` with a real tool (the smoke test sends neither
  header, so every row reads `other`), and `X-Forwarded-For` when a client
  sends its own (it carries the caller's address through Front Door)
- [x] Front Door to the gateway over Private Link
- [x] Client address check: with public access Enabled, a direct call with a
  forged `X-Azure-SocketIP: 8.8.8.8` gets 401 (the header is ignored), as do
  forged `X-Forwarded-For` and both together; with public access Disabled direct
  calls are refused by the platform; through Front Door the same calls get 401
- [x] Risk tests through Front Door: bodies up to 70 MB pass (the 25 and 70 MB
  ones got the gateway's own 429 token limit); a streamed Claude call survived
  249 seconds
- [x] TLS at Front Door: 1.2 and 1.3 only
- [x] Certificate chain on the custom domain: RSA 4096 leaf plus the issuing CA,
  verified, TLS 1.3
- [x] Hardening check script: portal off, no secrets, Foundry local auth off,
  tracing off
- [x] Front Door access and WAF logs arrive in the v2 workspace (212 and 110
  rows in 48 hours, newest 2026-11-27 08:54 EST, in `AzureDiagnostics`). No
  health probe rows appeared: check whether probes run for a single origin
- [x] `model-router`: the live routers of dev and prod route across 12 models,
  `gpt-6-luna` among them. The settings listed 8, so they were corrected (and
  the router catalogs regenerated); see aifapim-config
- [x] Event Hub, logger, global policy and WAF managed rules deployed on dev,
  2026-11-27. The first deploy failed three times, each fixed in the template:
  APIM's management plane tests the logger connection from outside the VNet and
  is refused unless the namespace allows trusted services (now on); the HTTP
  DDoS rule set takes no action (the API refuses one); and `master` cannot be
  declared (see the hardening checklist)
- [x] Security events against gateway requests: a run of 12 probe calls (valid
  and bad keys, unknown path, unknown model, `/catalog`, five prompts) made 8
  requests reach the gateway and 8 hub messages arrived about a minute later,
  so refused requests (401, 404) and `/catalog` (`return-response`) are in the
  hub. The 4 calls the WAF blocked never reach the gateway or the hub: they
  appear only in the WAF log. Counts only; no event has been read
- [x] WAF body check: with it on, 4 of 5 coding prompts got a Front Door 403
  (shell command: RCE 932xxx; `<script>` tag: XSS 941xxx; `../../../etc/shadow`:
  LFI 930xxx; an `eval` code review: PHP 933160, Node.js 934100, RCE). Only the
  SQL text passed. Earlier clean runs ran before the WAF change reached Front
  Door (15 to 30 minutes) and proved nothing about the WAF. Decision: off in dev
  and prod (`wafInspectRequestBody = false`); the default rule set still checks
  the URL, query, headers and cookies, and the bot manager only logs
  (`UnknownBots` for script clients). To redeploy and re-test: all four blocked
  prompts must return 200. An image-edit prompt through the WAF is not tested

To do:

- [ ] Smoke test by the host name, once DNS exists
- [ ] Caller matrix: an internal key works from the NAT pool and gets 403
  through Hermes, as on Classic; a caller outside the allowed range (needs a
  source address outside the NAT pool)
- [ ] Hermes egress addresses on the prod WAF list
- [ ] Outbound flows, then add the deny-Internet rule on the `int` subnet. It
  needs an allow for 443 to the `pe` subnet first (the request body log, the
  Event Hub and the Foundry accounts), or the body log stops without an error
- [ ] CPU and memory of one unit under calls that reach a model (the burst
  above did not)
- [ ] Request log, certificate renewal, expiry alert
- [ ] Rollback test: bind the v2 host name on Classic dev, then move DNS to
  Classic and back
- [ ] Decide whether the one-at-a-time deploy ordering is still needed
- [ ] Agent client: one call per tool (opencode, opencode 2, Claude Code, Codex)
  through the dev gateway, then read `Request-User-Agent` and
  `Request-X-Agent-Client` back from `AppRequests` and fix the `User-Agent`
  patterns in all five policies together (the patterns are from memory). The
  two headers must reach the gateway unchanged through Front Door
- [x] Grafana: Dev v2 in the Environment variable and a v2 edge row (Front Door,
  WAF, gateway CPU and memory, `Agent Client`, Classic against v2); every
  workspace query run against the dev v2 workspace. Still to do: the reader
  roles for the Grafana app (Log Analytics Reader on `law-rckovrtmvdr3y`,
  Monitoring Reader on `apim-dev-rckovrtmvdr3y`), import, and the memory panel
  (a metrics query not tried in Grafana yet); Prod v2 when the stack exists

### Phase 4: prod

- [ ] Network, gateway and Front Door for `aifapimv2`; same tests with pilot
  users

### Phase 5: move users

- [ ] Keys, host name announcement, Slack key workflow, OpenCode configuration,
  documentation, Hermes origin

### Phase 6: remove Classic

- [ ] Delete the Classic instances, their subnets, NSG, route table and
  identities; update `AGENTS.md`, `README.md`, `docs/apim-advisory-response.md`
- [ ] Sync the Classic prod certificate at a quiet time if Classic is still
  running
- [ ] Decide whether `aifapim.nsls2.bnl.gov` is retired or points at v2

Rollback before phase 6: point DNS and Hermes back at Classic, which keeps its
keys and configuration. Pointing the new host name at Classic does not make it
serve that name: Classic has no custom domain or certificate for it, so clients
would fail TLS validation. So before users move (phase 5), Classic gets the v2
host name as a second custom domain with the same Key Vault certificate (Classic
Developer allows several, and keeps its existing host name), tested in dev.
Without that, a rollback means every client changes its host name back.

## Hardening checklist

From Microsoft's "Secure your Azure API Management deployment" and the
"Azure API Management (Classic): Log Review Guide" (25 November 2026), whose
own advice is to keep secrets in Key Vault, use an internal virtual network and
consider v2. Items are checked in dev (phase 3) and again in prod.

Decided:

- [x] Built-in all-access subscription (`master`) suspended by hand after the
  first deployment (a template cannot: APIM answers a write with "Can't modify
  global subscription", and a template that declares it fails with "Subscription
  scope should be one of '/apis', '/apis/{apiId}', '/products/{productId}'",
  tried on dev 2026-11-27); checked on dev. Its keys skip every
  product policy, including the Entra token check of the agent products.
  Nothing in a template keeps it suspended, so the check script is run again
  after each deployment and before prod is announced.
- [x] `allowTracing: false` on every subscription the key tooling makes
  (`apim-subscriptions.bicep`, companion repository); the gateway template makes
  none. Checked on dev: `master` and `svc-v2-smoke` both read false. A
  subscription made another way is not covered, and nothing enforces it
  afterwards: the check script (`v2-hardening-check.py`) only reports each
  subscription's state and tracing, so run it after every key change.

Network:

- [x] Outbound through our virtual network to private endpoints (network
  template)
- [x] Gateway public network access Disabled; only the approved Front Door
  Private Link connection reaches it
- [x] WAF allow-list at Front Door on `SocketAddr`; the policies' allow-list and
  product checks read the same `clientAddress`
- [ ] Deny outbound Internet on the `int` subnet, once the flows are known
- [x] WAF managed rules (default 2.2, bot manager 1.1, HTTP DDoS 1.0, whose
  rules log by default) in the template. To settle on dev: how much of a body
  the WAF inspects, whether Premium includes the managed rules at no extra
  charge (the Front Door bill will show), and which of the prompts in the tests
  it blocks
- [x] WAF body check off (`wafInspectRequestBody = false`): real prompts with
  code, shell and paths are blocked by the default rule set; exclusions for every
  field that carries content would leave almost nothing to inspect. Prompt
  content is for the model provider's content filters. Prod follows dev
- [ ] DDoS protection: decide what Front Door Premium and the HTTP DDoS rule set
  give and whether more is needed (Azure DDoS Protection is not available for
  the v2 tiers)

TLS:

- [x] Front Door accepts TLS 1.2 and 1.3 only
- [ ] Certificates from Key Vault with an expiry alert (phase 3)

Identity and access:

- [ ] Least-privilege roles on the v2 instances: review the role assignments
  (Service Reader or Operator instead of Contributor or Owner), and the
  inherited subscription roles (prefer PIM)
- [ ] Conditional Access with MFA for the people who administer APIM, its
  policies, the vault and the network
- [ ] Subscription keys are not authentication: keep the Entra ID token on the
  agents and open products, and the NAT-pool lock on the internal products
- [ ] System-assigned identity for Key Vault; no credential stored in APIM (no
  named-value secrets, no backend keys, local authentication off on Foundry,
  Event Hub and storage)
- [ ] Developer portal off; no users, identity providers or sign-up

Logging and monitoring:

- [x] Security events: one JSON line per request to the Event Hub (who, what,
  outcome; no prompt text), over a private endpoint. Trade-off: the namespace
  allows trusted Microsoft services and the NAT pool from outside the VNet,
  because APIM's management plane validates the logger from outside it; local
  authentication stays off, so a caller still needs an Entra role
- [ ] Decide the destination of the events (SIEM): the plan is Alloy on a host
  reading the hub into a new Loki tenant (`n2sn-aifapim`, provisional); the
  data classification, volume, host, port 9093 egress, Alloy's certificate
  sign-in and the read role are open

- [ ] Gateway and LLM logs to Log Analytics; v2 CPU and memory metrics with an
  alert in place of the Classic capacity metric
- [x] Activity log export and Key Vault audit log (NSLS2/bicep)
- [ ] Entra sign-in and audit logs for the apps used by APIM
- [ ] Defender for APIs and the built-in Azure Policy definitions for APIM
  (virtual network, encrypted protocols): decide

Governance and recovery:

- [ ] CanNotDelete lock and tags on both resource groups
- [ ] Decide request and response validation: a cap on the request body size
  and removal of backend headers from responses
- [ ] Later: a real per-key ceiling (tokens per minute is 10,000,000 today, so
  it limits nothing)
- [ ] Zone redundancy for prod (`zoneRedundant`, set when the instance is created)
- [ ] The v2 tiers have no backup and restore: the configuration is this
  repository, and the subscription keys are kept as an encrypted snapshot
  (`rotate-keys.py snapshot` in the companion repository) after every change
- [ ] Direct management API and Git configuration: not available on v2, nothing
  to turn off

## Open questions

- Who or what widened the live router lists from 8 to 12 models (the router
  version is updated in place by Microsoft, and the activity log showed no write
  to read with the read-only identity). The settings now match the live
  routers.
- The real `User-Agent` strings of opencode, Claude Code and Codex (phase 3).
  The token metrics keep all their dimensions on v2: checked against Classic.
- Hermes egress addresses: no longer needed for an allow-list (prod is public
  with a key). What Hermes' WAF (sigsci) does today is not known; the edge rules
  and the rate limit are set from the Hermes traffic in the Classic gateway log.
- What the Front Door request and transfer charges come to (its access and WAF
  logs reach the v2 workspace).
- CPU and memory of one Standard v2 unit under calls that reach a model (the
  `/catalog` burst peaked at 4% CPU; memory did not move). In the 24 hours to
  09:29 EST on 2026-11-27, with the smoke and risk tests the only load, the
  hourly peaks were 31% CPU (21:29 EST on 26 November) and 35.6% memory (20:29
  EST). Memory then reads about 0 for the rest of the day while the gateway
  kept answering, so the memory metric is not trusted (the burst did not move
  it either). Also whether a second unit is billed at the secondary-unit rate.
- The effect of deny-Internet outbound on the integrated instance (phase 3).
- **Log Analytics is unreachable from the NSLS-II network (found 2026-11-27,
  fix parked).** The site resolvers (`10.65.2.25` and `.26`) answer
  `api.loganalytics.io` and `api.loganalytics.azure.com`, through
  `api.privatelink.monitor.azure.com`, with `10.8.64.7`. That address is not in
  our subscription (our networks are 10.0 to 10.3 and 10.11; no interface of ours
  holds it) and is not routable from N2SN: from `grafana1` the connection times
  out, and so does `10.8.104.68` in our own peered BNL spoke
  (`bnl-vnet-SciNSLS2-use-prod`, peered to `bnl-vnet-hub-prod`). All four of our
  workspaces are in our own Azure Monitor private link scopes only, so the
  address is BNL's: very probably a BNL private link scope whose DNS zone reached
  the NSLS-II resolvers. It showed first as Grafana saying "No data" for every
  panel (`dial tcp 10.8.64.7:443: i/o timeout`), and it also stops `devcheck
  latency`, `verify.sh` and `az monitor log-analytics query` from N2SN (my notes
  show the sandbox already failed on 2026-11-24; when Grafana started is not
  known). **Workaround in place:** `40.113.176.131 api.loganalytics.io
  api.loganalytics.azure.com # TEMP aifapim test` in `/etc/hosts` on `grafana1`,
  `grafana2` and `grafana3` (proved with a Grafana query probe: all workspaces
  ok; Ansible may remove it, and it breaks if Azure moves the address).
  **To fix:** a ticket to whoever runs the resolvers, to answer the Azure
  Monitor private-link zones from public DNS for N2SN
  (`privatelink.monitor.azure.com` and the `opinsights` and automation zones),
  or to route N2SN to `10.8.64.7` and confirm that scope's query access is
  Open. Then remove the `/etc/hosts` lines
  (`sed -i '/# TEMP aifapim test/d' /etc/hosts`). The private blob names
  (`*.blob.core.windows.net`) do not resolve from N2SN either, so
  byte-for-byte body storage is checked only from a host inside the VNet.
- Whether the Front Door custom-domain deployment (more than 15 minutes) and the
  30 minutes Front Door takes to publish a change are acceptable for the prod
  cutover.

## MOSAIC (microsoft/mosaic-apim)

A reference, not part of this migration. It is a governance layer over APIM
(catalog, grants by Entra group, cost centres, budgets), MIT licensed and not a
supported Azure service. Ideas to reuse: Anthropic token metering on v2 tiers,
backend pools with circuit breakers instead of hand-written retry and failover
policies, its Standard v2 network layout (the same integration subnet design
used here), Entra group grants. Adopting it whole is a separate project after
the migration.

## Sources

- API Management v2 tiers, Premium v2 injection, outbound integration, tier
  changes, networking options (Microsoft Learn, `api-management/`
  `v2-service-tiers-overview`, `inject-vnet-v2`, `integrate-vnet-outbound`,
  `upgrade-and-scale`, `virtual-network-concepts`)
- Key Vault trusted services (`key-vault/general/overview-vnet-service-endpoints`)
- Front Door Private Link to API Management, custom domains with a Key Vault
  certificate and the WAF `SocketAddr` match variable (Microsoft Learn,
  `frontdoor/`)
- API Management feature comparison and reliability (`api-management/`
  `api-management-features`, `reliability/reliability-api-management`)
- API Management managed identity and Key Vault firewall requirements
  (`api-management/api-management-howto-use-managed-service-identity`)
- Azure Retail Prices API, East US, 2026-11-26
