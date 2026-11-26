# Moving AIFAPIM to API Management v2

Plan for moving the AIFAPIM gateways from API Management Classic (Developer
tier) to **Premium v2**, as two new gateway-only stacks, `aifapimv2` (prod) and
`aifapimv2-dev`, built beside the Classic ones. This file is the master plan
(design, costs, phases). The settings, key tooling and scripts are planned in
`docs/apim-v2-migration.md` of
[aifapim-config](https://github.com/NSLS2/aifapim-config), the companion repo.

Last updated 2026-11-26. The checkboxes in "Phases" are ticked in this pull
request as work lands.

## Status

| Piece | State |
| --- | --- |
| Design and names | Decided (see "Decisions") |
| Gateway certificates (`aifapimv2`, `aifapimv2-dev`) | Issued and in Key Vault |
| Certificate renewal playbook | NSLS2/ansible pull request 5178 |
| Key Vault firewall template | Committed, subnet entries wait for the network |
| Dev network template (`aifapimv2-network.bicep`) | In this pull request |
| Gateway template (`aifapimv2.bicep`) | Not started |
| DNS records | Waiting; test with Azure-generated names |
| Public IP policy exemption for the Application Gateway | **Not confirmed; blocks the gateway stage** |

## Why, and what Microsoft gives us

There is no in-place upgrade from Classic to v2, so each v2 instance is a new
service and the configuration is replicated. Reasons to move:

- Classic Developer has no SLA and one unit. The Classic advisory response
  (`MZK9-GH0`) left "move off Classic to a v2 tier" as its last open item.
- The Anthropic logging gaps (completion tokens always 0, empty model name for
  streaming, missing prompts) may be fixed on v2. Microsoft lists the Anthropic
  Messages API as supported in the v2 tiers. This is to be measured in dev.
- Premium v2 supports availability zones, up to 30 units, and full virtual
  network injection (private gateway address, no public IP).

What v2 does not have (Microsoft, 2026-11): multi-region, backup and restore,
Git configuration, direct management API access, cipher configuration, the
service-wide CA certificate list, built-in analytics, resource move. None of
these is used by this repository, to be confirmed by a search before dev.

## Target design

```text
Callers (Hermes WAF, NAT pool, Anthropic, others on the allow-list)
        |  HTTPS 443, NSG allows only gatewayInboundSources
        v
Application Gateway Standard v2          subnet agw   (public IP)
        |  HTTPS 443, only path into the apim subnet
        v
API Management Premium v2 (1 unit)       subnet apim  (private IP, injected)
        |  managed identity, private endpoints
        v
Existing Foundry accounts (East US, East US 2)     subnet pe
```

| | aifapimv2 (prod) | aifapimv2-dev |
| --- | --- | --- |
| Resource group | `rg-aifapimv2-prod-1` | `rg-aifapimv2-dev-1` |
| Host name | `aifapimv2.nsls2.bnl.gov` | `aifapimv2-dev.nsls2.bnl.gov` |
| Network | `net-aifapimv2-prod`, 10.10.0.0/16 | `net-aifapimv2-dev`, 10.11.0.0/16 |
| Subnets | `apim` .0/24, `agw` .1/24, `pe` .2/24 | same offsets |
| Backends | Foundry accounts in `rg-aif-apim-prod-1` | those in `rg-aif-apim-dev-1` |

- **Gateway only.** Foundry accounts, model deployments and their quota stay
  where they are. Quota in East US and East US 2 is largely allocated already,
  so duplicating the deployments is not an option. The v2 gateway reaches them
  through its own private endpoints and private DNS zones (two endpoints to one
  account cannot share a zone). The accounts' diagnostics stay in the Classic
  stack's Log Analytics until Classic is removed.
- **Firewall rules.** The network security group of the `agw` subnet admits only
  `gatewayInboundSources` on 443 plus the Application Gateway management ports.
  The `apim` subnet admits only the `agw` subnet. This is the reason for
  Premium v2 (Standard v2 cannot be injected; it keeps a public gateway).
- **No hub peering.** The networks stay stand-alone. All callers already reach
  a public address, so a private link to the BNL network has little benefit.
- **Public address.** The Application Gateway needs a public IP resource, which
  the BNL policy currently denies: see "Public IP policy".
- **Network first.** Premium v2 placement in a network is fixed at creation, and
  a Key Vault network rule needs an existing subnet, so the network
  (`aifapimv2-network.bicep`) is deployed on its own, then the vault rule, then
  the gateway (`aifapimv2.bicep`).
- **TLS.** The Application Gateway serves the `aifapimv2(-dev)` certificate from
  Key Vault (user-assigned identity, trusted-service bypass plus the subnet
  rule). Classic cipher settings move to the Application Gateway TLS policy.
- **Testing without DNS.** Use the Application Gateway's Azure DNS label
  (`<label>.eastus.cloudapp.azure.com`) or its public IP with
  `curl --resolve aifapimv2-dev.nsls2.bnl.gov:443:<ip>`; the certificate is for
  the nsls2.bnl.gov name.

## What changes in the code (Classic to v2)

| Area | Today (Classic) | On v2 |
| --- | --- | --- |
| Network | Injected in External mode, NSG and route table in `network.bicep` | New `aifapimv2-network.bicep`; Premium v2 injection, private address |
| API version | `2023-03-01-preview` | `2024-05-01` or later for v2 |
| TLS ciphers | `customProperties` in `api-management-private.bicep` | Not available; Application Gateway TLS policy |
| CA certificates | `certificates` list (InCommon) | Per backend only; check whether needed at all |
| Caller address | `ip-filter` sees the caller | Sees the Application Gateway; read the last `X-Forwarded-For` entry |
| Inbound lock | `gatewayInboundSources` on the APIM subnet NSG | Same list on the `agw` subnet NSG |
| Custom domain | APIM custom host name | Application Gateway listener; APIM keeps its default name behind it |
| Gateway to storage, Event Hub | Trusted-service bypass or private endpoint | Private endpoints (trusted-service access for the gateway data plane ended March 2026) |
| Deploy ordering | One-at-a-time writes (Developer "ServiceLocked race") | Kept first, relax after dev shows it is not needed |
| Subscriptions | People, services, beamlines, catalog poller | Recreated with the same key values (companion repo) |

The caller-address change is the one that needs care. The NAT-pool lock on the
internal and agents products, and the global allow-list, assume the gateway
sees the real caller. Behind the Application Gateway the connecting address is
the gateway's, so the policies must trust `X-Forwarded-For` only when the
connection comes from the `agw` subnet, and read its **last** entry. The WAF
already appends to the header, so the first entry is client controlled (see
"The internal lock sees the caller the gateway sees" in `AGENTS.md`).

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

| Tier | Per unit per month | Notes |
| --- | --- | --- |
| Developer (today) | $48 | No SLA |
| Basic v2 | $150 | No network integration: cannot reach the private endpoints |
| Standard v2 | $700 | Public gateway only (inbound limited by policy) |
| Premium v2 | $2,800 | Injection; chosen |
| Application Gateway Standard v2 | about $150 to $180 | Fixed charge plus capacity units |

Premium v2 plus the Application Gateway is about $2,970 a month per
environment, about $5,940 for dev and prod together, about $5,840 more than
today (roughly 15% of October's prod spend). A second prod unit would add
$1,400 to $2,800 depending on whether Microsoft bills it at the secondary-unit
rate ($1.91781 an hour); this is not confirmed. One unit is expected to be
enough, to be shown in dev (phase 3). Private endpoints add about $7 each.

## Public IP policy (blocker for the gateway stage)

A BNL management-group policy ("Deny public IPs", `Not allowed resource types`)
blocks `Microsoft.Network/publicIPAddresses`; the first Classic dev deployment
failed on it (a NAT gateway), see `AGENTS.md`. An Application Gateway with a
public front end needs such a resource, so the Application Gateway cannot be
deployed until the policy is lifted for these resource groups. The network
stage (`aifapimv2-network.bicep`) creates no public address and is not
affected. Classic works because its gateway address belongs to API Management,
not to a public IP resource of ours.

Ways forward, in order of preference:

1. **Exemption** of the two resource groups (`rg-aifapimv2-dev-1` first) from
   the policy, requested from the cloud administrators. Needed before phase 2
   deploys the gateway.
2. **Standard v2 without an Application Gateway.** The gateway keeps an
   API Management address (expected to be allowed, as for Classic). Cost drops
   to about $700 a month per stack, but the inbound lock is the `ip-filter`
   policies alone, not a network security group, and the subnet-level firewall
   rules that motivated Premium v2 are lost.
3. **Azure Front Door** (a Microsoft-managed edge) in front of a Premium v2
   gateway. Not investigated: whether it can reach an injected instance, what it
   costs, and whether the policy affects it.

Private-only (a Private Application Gateway with Network Isolation, or the
Premium v2 gateway alone) does not serve the callers: Hermes and the Anthropic
addresses connect from outside, and the AIFAPIM networks are not connected to
the BNL network.

## Certificates

- `aifapimv2` and `aifapimv2-dev` were issued on 2026-11-26 with the
  `acme_certificates` role and imported into the Key Vault
  `acme-tls-certificates`. They expire 2027-06-12; renew from 2027-05-15.
- Renewal is `aifapim_gateway_certificates.yml` in NSLS2/ansible (pull request
  5178). It reads the expiry from Key Vault, issues when under 28 days remain,
  imports with `az` as the calling user, and removes its temporary directory.
- Not yet checked: that the imported PFX carries the intermediate certificates
  (look at the chain the dev gateway serves). An alert on the expiry of the
  certificate each gateway serves belongs in phase 3 (`alert-rules` skill).

## Key Vault firewall

The vault denies by default, allows trusted Microsoft services, the NAT pool,
and the two Classic `apim` subnets. For v2 the `agw` subnets are added as
network rules (Microsoft's documented requirement for Application Gateway, with
the `Microsoft.KeyVault` service endpoint on the subnet). The v2 `apim` subnet
is not listed: APIM reads its custom-domain certificate as a trusted service
(system-assigned identity, control-plane call). Add it only if dev cannot read
the certificate. The template is in NSLS2/bicep, `azure/infra-certificates`.

## Decisions

- Tier: Premium v2 behind an Application Gateway, for prod and dev alike.
- Stacks: gateway only, reusing the Foundry accounts; names as in the table.
- No peering to the BNL hub; no DNS records yet (Azure-generated names first).
- This template supports v2 only. Classic stays at the last `main` commit
  before this change until it is removed; an urgent Classic fix is made from a
  branch of that commit.
- aifapim is merged first: the companion settings load
  `../aifapim/aifapimv2*.bicep`.
- The built-in all-access subscription is turned off on both v2 instances.
- Request tracing is turned off on every subscription.

## Phases

Dev always goes before prod.

### Phase 0: prerequisites

- [ ] **Public IP policy: exemption for the Application Gateway, or a decision
  on the alternatives** (see "Public IP policy"); gates phase 2
- [x] Tier, design and names decided
- [x] Certificates issued and in Key Vault
- [x] Certificate renewal playbook (NSLS2/ansible pull request 5178)
- [x] Key Vault firewall template prepared (NSLS2/bicep)
- [ ] Explain the November Log Analytics cost in prod
- [ ] Search the repository for Classic-only features (see "Why")
- [ ] Decide: copy existing key values to v2, or issue new keys
- [ ] Decide: Hermes route for `aifapimv2`, or direct to the Application Gateway
- [ ] DNS records for both host names (after the first dev tests)

### Phase 1: templates and settings

- [x] `aifapimv2-network.bicep` and `aifapimv2-dev-network.bicepparam`
- [ ] `aifapimv2.bicep`: Application Gateway, APIM Premium v2, private
  endpoints and DNS zones for the existing Foundry accounts, role assignments,
  logging, request log
- [ ] Policies: caller address behind the Application Gateway; update
  `tests/policy/caller-policy-test.ps1`
- [ ] API version `2024-05-01` or later in the shared modules
- [ ] Settings for the gateway (`aifapimv2-dev.bicepparam`, prod)
- [ ] Key copy script and the scripts that name the APIM resource (companion)

### Phase 2: deploy dev

- [ ] Create `rg-aifapimv2-dev-1` and deploy the network
- [ ] Add the dev `agw` subnet to the vault firewall and deploy it
- [ ] Deploy the gateway; capture the Application Gateway address

### Phase 3: test dev

- [ ] Smoke test and health probes (`test-models.py`)
- [ ] Caller-address matrix: an internal key works from the NAT pool, gets 403
  through Hermes and with a forged `X-Forwarded-For`
- [ ] Outbound flows, then add the deny-Internet rule on the `apim` subnet
- [ ] Anthropic token metering and the logging gaps versus Classic
- [ ] CPU and memory of one unit, including a repeat of the 55 requests per
  second burst
- [ ] Request log, certificate chain, renewal, expiry alert
- [ ] Decide whether the one-at-a-time deploy ordering is still needed

### Phase 4: prod

- [ ] Network, vault rule, gateway for `aifapimv2`; same tests with pilot users

### Phase 5: move users

- [ ] Keys, host name announcement, Slack key workflow, OpenCode configuration,
  documentation, Hermes route

### Phase 6: remove Classic

- [ ] Delete the Classic instances, their subnets, NSG, route table and
  identities; update `AGENTS.md`, `README.md`, `docs/apim-advisory-response.md`
- [ ] Decide whether `aifapim.nsls2.bnl.gov` is retired or points at v2

Rollback before phase 6: point DNS and Hermes back at Classic, which keeps its
keys and configuration.

## Hardening checklist

From Microsoft's "Secure your Azure API Management deployment" and the
"Azure API Management (Classic): Log Review Guide" (25 November 2026), whose
own advice is to keep secrets in Key Vault, use an internal virtual network and
consider v2. Items are checked in dev (phase 3) and again in prod.

Decided:

- [ ] Built-in all-access subscription (`master`) turned off: suspended in the
  template, or removed if APIM allows it; its state is checked in dev.
- [ ] `allowTracing: false` on every subscription, in the gateway template and
  in the key tooling of the companion repository.

Network:

- [x] Gateway injected in a virtual network with a private address; the only
  public entry is the Application Gateway (network template)
- [x] `agw` subnet admits only the allowed sources; `apim` subnet admits only
  `agw` (network template)
- [ ] Deny outbound Internet on the `apim` subnet, once the flows are known
- [ ] `ip-filter` policies kept, reading `X-Forwarded-For` safely
- [ ] Application Gateway with a web application firewall: decide (see "Open
  questions")
- [ ] DDoS protection: Azure DDoS Protection is not available for the v2
  tiers; decide whether the Application Gateway's public address needs it

TLS:

- [ ] Application Gateway TLS policy: TLS 1.2 or later, strong ciphers only
  (the v2 tiers cannot set ciphers)
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

- [ ] Gateway and LLM logs to Log Analytics; v2 CPU and memory metrics with an
  alert in place of the Classic capacity metric
- [x] Activity log export and Key Vault audit log (NSLS2/bicep)
- [ ] Entra sign-in and audit logs for the apps used by APIM
- [ ] Alert on unhealthy Application Gateway backends
- [ ] Defender for APIs and the built-in Azure Policy definitions for APIM
  (virtual network, encrypted protocols): decide

Governance and recovery:

- [ ] CanNotDelete lock and tags on both resource groups
- [ ] The v2 tiers have no backup and restore: the configuration is this
  repository, and the subscription keys are kept as an encrypted snapshot
  (`rotate-keys.py snapshot` in the companion repository) after every change
- [ ] Direct management API and Git configuration: not available on v2, nothing
  to turn off

## Open questions

- Whether the public IP policy can be lifted for these groups, or which
  alternative is used (see "Public IP policy").
- Whether a second Premium v2 unit is billed at the secondary-unit rate.
- Whether the v2 `apim` subnet needs a Key Vault network rule.
- The effect of deny-Internet outbound on a Premium v2 instance (phase 3).
- Whether the PFX in Key Vault serves the intermediate certificates.
- A web application firewall on the Application Gateway. Hermes is the WAF for
  callers that go through it, but callers from the NAT pool connect directly.
  The WAF SKU costs about $0.36 an hour fixed against $0.20 for the standard
  one (about $115 more a month per stack), plus a higher capacity-unit charge.

## MOSAIC (microsoft/mosaic-apim)

A reference, not part of this migration. It is a governance layer over APIM
(catalog, grants by Entra group, cost centres, budgets), MIT licensed and not a
supported Azure service. Ideas to reuse: Anthropic token metering on v2 tiers,
backend pools with circuit breakers instead of hand-written retry and failover
policies, its Standard v2 network layout, Entra group grants. Adopting it
whole is a separate project after the migration.

## Sources

- API Management v2 tiers, Premium v2 injection, networking options
  (Microsoft Learn, `api-management/v2-service-tiers-overview`,
  `inject-vnet-v2`, `virtual-network-concepts`)
- Key Vault trusted services and Application Gateway Key Vault certificates
  (`key-vault/general/overview-vnet-service-endpoints`,
  `application-gateway/key-vault-certs`)
- API Management managed identity and Key Vault firewall requirements
  (`api-management/api-management-howto-use-managed-service-identity`)
- Azure Retail Prices API, East US, 2026-11-26
