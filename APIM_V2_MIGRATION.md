# Moving AIFAPIM to API Management v2

Plan for moving the AIFAPIM gateways from API Management Classic (Developer
tier) to v2, as two new gateway-only stacks, `aifapimv2` (prod) and
`aifapimv2-dev`, built beside the Classic ones, in **two stages**:

1. **Now: Standard v2.** A public gateway on an address owned by API
   Management, with outbound traffic through our virtual network. It needs no
   public IP resource of ours, which a BNL policy denies.
2. **Later: Premium v2 behind an Application Gateway**, for network-level
   inbound firewall rules, once a public IP can be created. Microsoft offers
   no in-place upgrade from Standard v2 to Premium v2, so this is a second,
   smaller migration to a new instance.

This file is the master plan (design, costs, phases). The settings, key tooling
and scripts are planned in `docs/apim-v2-migration.md` of
[aifapim-config](https://github.com/NSLS2/aifapim-config), the companion repo.

Last updated 2026-11-26. The checkboxes in "Phases" are ticked in this pull
request as work lands.

## Status

| Piece | State |
| --- | --- |
| Design, names, two stages | Decided (see "Decisions") |
| Gateway certificates (`aifapimv2`, `aifapimv2-dev`) | Issued and in Key Vault |
| Certificate renewal playbook | NSLS2/ansible pull request 5178 |
| Key Vault firewall template | Deployed; dev `agw` rule kept for stage 2 |
| Dev network (`aifapimv2-network.bicep`) | Deployed 2026-11-26; integration subnet to add |
| Gateway template (`aifapimv2.bicep`, Standard v2) | Written; not deployed. No request body log or Event Hub yet |
| DNS records | Waiting; test on the default `azure-api.net` name |
| Public IP policy | Not a blocker for stage 1; blocks stage 2 |

## Why, and what Microsoft gives us

There is no in-place upgrade from Classic to v2, so each v2 instance is a new
service and the configuration is replicated. Reasons to move:

- Classic Developer has no SLA and one unit. The Classic advisory response
  (`MZK9-GH0`) left "move off Classic to a v2 tier" as its last open item.
- The Anthropic logging gaps (completion tokens always 0, empty model name for
  streaming, missing prompts) may be fixed on v2. Microsoft lists the Anthropic
  Messages API as supported in the v2 tiers. This is to be measured in dev.
- Standard v2 and Premium v2 have an SLA and several units (Standard v2 up to
  10, Premium v2 up to 30). Premium v2 supports availability zones. For
  Standard v2 Microsoft's pages disagree (the reliability page lists zone
  redundancy, the tier comparison does not), so zones are not relied on for
  stage 1; the setting can only be chosen when the instance is created, so check
  it then.

What v2 does not have (Microsoft, 2026-11): multi-region, backup and restore,
Git configuration, direct management API access, cipher configuration, the
service-wide CA certificate list, built-in analytics, resource move. None of
these is used by this repository, to be confirmed by a search before dev.

## Stage 1 design: Standard v2

```text
Callers (Hermes WAF, NAT pool, Anthropic, others on the allow-list)
        |  HTTPS 443, public address owned by API Management
        |  access control: ip-filter policies and keys (as on Classic prod)
        v
API Management Standard v2 (1 unit)      host name aifapimv2(-dev).nsls2.bnl.gov
        |  outbound through subnet `int` (delegated, NSG), managed identity
        v
Private endpoints in subnet `pe` -> existing Foundry accounts (East US, East US 2)
```

| | aifapimv2 (prod) | aifapimv2-dev |
| --- | --- | --- |
| Resource group | `rg-aifapimv2-prod-1` | `rg-aifapimv2-dev-1` |
| Host name | `aifapimv2.nsls2.bnl.gov` | `aifapimv2-dev.nsls2.bnl.gov` |
| Network | `net-aifapimv2-prod`, 10.10.0.0/16 | `net-aifapimv2-dev`, 10.11.0.0/16 |
| Subnets | `int` .4/24, `pe` .2/24 (`apim` .0/24 and `agw` .1/24 reserved) | same offsets |
| Backends | Foundry accounts in `rg-aif-apim-prod-1` | those in `rg-aif-apim-dev-1` |

- **Gateway only.** Foundry accounts, model deployments and their quota stay
  where they are. Quota in East US and East US 2 is largely allocated already,
  so duplicating the deployments is not an option. The v2 gateway reaches them
  through its own private endpoints and private DNS zones (two endpoints to one
  account cannot share a zone). The accounts' diagnostics stay in the Classic
  stack's Log Analytics until Classic is removed.
- **Outbound through our network.** Standard v2 integrates with a delegated
  subnet (`Microsoft.Web/serverFarms`, at least /27, one instance only) with an
  NSG that allows outbound 443 to `AzureKeyVault`. Backends in the network,
  including private endpoints, are reachable. Inbound NSG rules do not apply to
  an integrated instance (Microsoft).
- **Inbound control is policy only.** The `ip-filter` allow-list and the
  product locks work exactly as on Classic prod, which also has no network-level
  lock. Dev loses the NAT-pool-only network rule it has on Classic; callers
  outside the list get a 403 from the gateway instead.
- **Real client address.** There is no proxy in front, so the gateway sees the
  caller as on Classic, and the policies need no change for `X-Forwarded-For`.
- **No hub peering.** The networks stay stand-alone.
- **Own host name from the start.** The gateway serves
  `aifapimv2(-dev).nsls2.bnl.gov` as its one custom domain (Standard v2 allows
  only one) with the Key Vault certificate (system-assigned identity,
  trusted-service bypass). Stage 2 moves that name to the Application Gateway
  with a DNS change, so users change their host name only once. Until DNS
  exists, test on the default `<name>.azure-api.net` address.
- **The gateway is deployed in two steps.** The system-assigned identity exists
  only once the instance does, and it needs the Key Vault Secrets User role
  before it can read the certificate (the firewall bypass does not give that
  authorization). So the first deployment has no custom domain, the role is
  assigned, and a second deployment enables the domain once the role is in
  effect, as `vaultIdentity` already does for Classic in `aifapim.bicep`.
- **Network first.** The network (`aifapimv2-network.bicep`) is deployed on its
  own, then the gateway (`aifapimv2.bicep`).

## Stage 2 design: Premium v2 behind an Application Gateway

Premium v2 is injected into the virtual network (private address only) and a
public Application Gateway in front takes the traffic. The network security
group of the `agw` subnet then admits only the allowed sources, and the `apim`
subnet admits only the `agw` subnet: the network-level firewall rules that
motivated Premium v2. The `apim` and `agw` subnets and their NSGs are already
deployed (reserved) in the dev network.

- It needs a `Microsoft.Network/publicIPAddresses` resource for the Application
  Gateway, which a BNL policy denies: see "Public IP policy".
- It is a **new instance**: Microsoft allows tier changes only between the
  classic tiers and between Basic v2 and Standard v2, and a Premium v2 instance
  cannot switch between injection and integration. So the key copy, the tests
  and a DNS cutover are done again; the tooling is written to be repeated.
- Behind the Application Gateway the policies must read the last
  `X-Forwarded-For` entry, and only when the connection comes from the `agw`
  subnet (see "The internal lock sees the caller the gateway sees" in
  `AGENTS.md`); cipher settings move to the Application Gateway TLS policy.
- Cost: about $2,970 a month per stack (see "Usage and cost").

## What changes in the code (Classic to Standard v2)

| Area | Today (Classic) | On Standard v2 |
| --- | --- | --- |
| Network | Injected in External mode, NSG and route table in `network.bicep` | New `aifapimv2-network.bicep`; outbound integration subnet `int` |
| API version | `2023-03-01-preview` | `2024-05-01` or later for v2 |
| TLS ciphers | `customProperties` in `api-management-private.bicep` | Not available; platform defaults, checked in dev |
| CA certificates | `certificates` list (InCommon) | Per backend only; check whether needed at all |
| Inbound lock | `gatewayInboundSources` on the APIM subnet NSG (dev) | Policy only (`ip-filter`); an NSG does not apply |
| Caller address | `ip-filter` sees the caller | Same: no proxy in front |
| Custom domain | APIM custom host name | Same, on the v2 instance |
| Gateway to storage, Event Hub | Trusted-service bypass or private endpoint | Private endpoints (trusted-service access for the gateway data plane ended March 2026) |
| Deploy ordering | One-at-a-time writes (Developer "ServiceLocked race") | Kept first, relax after dev shows it is not needed |
| Subscriptions | People, services, beamlines, catalog poller | Recreated with the same key values (companion repo) |

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
| **Standard v2** | **$700** | Stage 1. 50 million calls included, so no call charge at today's volume |
| Premium v2 | $2,800 | Stage 2 |
| Application Gateway Standard v2 | about $150 to $180 | Stage 2: fixed charge plus capacity units |

- **Stage 1:** about $700 a month per stack plus about $7 for each private
  endpoint, about $1,400 for dev and prod together, about $1,300 more than today
  (roughly 3.5% of October's prod spend). A second unit is expected to cost
  about $500 (the Standard v2 secondary-unit rate, $0.68493 an hour), not
  confirmed. One unit is expected to be enough, to be shown in dev (phase 3).
- **Stage 2:** about $2,970 a month per stack, about $5,940 for both.

## Public IP policy

A BNL management-group policy ("Deny public IPs", `Not allowed resource types`)
blocks `Microsoft.Network/publicIPAddresses`; the first Classic dev deployment
failed on it (a NAT gateway), see `AGENTS.md`. Classic works because its gateway
address belongs to API Management, not to a public IP resource of ours.

- **Stage 1 is expected to be unaffected**, because a Standard v2 gateway also
  uses an address owned by the service. This is not verified: the first dev
  deployment of the gateway is the test. If it fails on the policy, the
  exemption below is needed for stage 1 too.
- **Stage 2 needs an exemption.** An Application Gateway with a public front
  end needs a public IP resource. Request it for the two resource groups
  (`rg-aifapimv2-dev-1` first) from the cloud administrators. Private-only
  designs do not serve the callers: Hermes and the Anthropic addresses connect
  from outside, and the AIFAPIM networks are not connected to the BNL network.
  Azure Front Door (a Microsoft-managed edge) in front of Premium v2 is a third
  option, not investigated.

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
and the subnets listed in `azure/infra-certificates` of NSLS2/bicep: the two
Classic `apim` subnets and, since 2026-11-26, the dev `agw` subnet.

- Stage 1: API Management reads its custom-domain certificate as a trusted
  service with its system-assigned identity (a control-plane call), so the
  Standard v2 instance needs no subnet rule, but it does need the Key Vault
  Secrets User role, granted after the instance exists (see "Stage 1 design").
  Add the `int` subnet only if dev cannot read the certificate.
- Stage 2: the `agw` subnet rule (Microsoft's documented requirement for
  Application Gateway, with the `Microsoft.KeyVault` service endpoint on the
  subnet) is already in place for dev.

## Decisions

- Tier: Standard v2 now, for prod and dev alike; Premium v2 behind an
  Application Gateway later, as a new instance. Reason: Premium v2 injection
  needs an Application Gateway with a public IP resource, which a BNL policy
  denies; Standard v2 does not.
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

- [x] Tier, design, names and the two stages decided
- [x] Certificates issued and in Key Vault
- [x] Certificate renewal playbook (NSLS2/ansible pull request 5178)
- [x] Key Vault firewall template deployed (NSLS2/bicep)
- [ ] Confirm with the cloud administrators that a Standard v2 instance (an
  address owned by API Management) is allowed under the "Deny public IPs"
  policy, before the first gateway deployment; ask for the stage 2 exemption at
  the same time (see "Public IP policy")
- [ ] Explain the November Log Analytics cost in prod
- [ ] Search the repository for Classic-only features (see "Why")
- [x] Decided: copy the existing key values to v2, so users change only the
  host name
- [ ] Decide: Hermes origin for `aifapimv2` (the custom host name directly)
- [ ] DNS records for both host names (after the first dev tests)

### Phase 1: templates and settings

- [x] `aifapimv2-network.bicep` and `aifapimv2-dev-network.bicepparam`
- [ ] Integration subnet `int` in the network template and settings
- [x] `aifapimv2.bicep`: APIM Standard v2 with the integration subnet and the
  custom domain, private endpoints and DNS zones for the existing Foundry
  accounts, role assignments, logging (policies, APIs and products rendered as
  in `aifapim.bicep`)
- [ ] Request body log in the v2 template (the Event Hub is not used, so it is
  left out)
- [x] API version 2024-05-01 in `modules/api.bicep`. Classic's `aifapim.bicep`
  builds with it too; run a what-if on Classic dev before any Classic redeploy
- [x] Settings for the dev gateway (`aifapimv2-dev.bicepparam`)
- [ ] Settings for the prod gateway
- [ ] Key copy script (same key values) and the scripts that name the APIM
  resource (companion)

### Phase 2: deploy dev

- [x] Create `rg-aifapimv2-dev-1` and deploy the network (2026-11-26)
- [x] Add the dev `agw` subnet to the vault firewall (kept for stage 2)
- [ ] Redeploy the network with the `int` subnet
- [ ] CanNotDelete lock on the resource group
- [ ] Deploy the gateway without the custom domain; this also shows whether the
  public IP policy blocks Standard v2
- [ ] Grant the Key Vault role, then deploy again with the custom domain

### Phase 3: test dev

- [ ] Smoke test and health probes (`test-models.py`) on the `azure-api.net`
  name
- [ ] Caller matrix: an internal key works from the NAT pool and gets 403
  through Hermes, as on Classic
- [ ] TLS: scan the gateway (TLS 1.0 and 1.1 refused, strong ciphers) since the
  tier cannot set ciphers
- [ ] Outbound flows, then add the deny-Internet rule on the `int` subnet
- [ ] Anthropic token metering and the logging gaps versus Classic
- [ ] CPU and memory of one unit, including a repeat of the 55 requests per
  second burst
- [ ] Request log, certificate chain, renewal, expiry alert
- [ ] Rollback test: bind the v2 host name on Classic dev, then move DNS to
  Classic and back
- [ ] Decide whether the one-at-a-time deploy ordering is still needed

### Phase 4: prod

- [ ] Network, gateway for `aifapimv2`; same tests with pilot users

### Phase 5: move users

- [ ] Keys, host name announcement, Slack key workflow, OpenCode configuration,
  documentation, Hermes origin

### Phase 6: remove Classic

- [ ] Delete the Classic instances, their subnets, NSG, route table and
  identities; update `AGENTS.md`, `README.md`, `docs/apim-advisory-response.md`
- [ ] Decide whether `aifapim.nsls2.bnl.gov` is retired or points at v2

Rollback before phase 6: point DNS and Hermes back at Classic, which keeps its
keys and configuration. Pointing the new host name at Classic does not make it
serve that name: Classic has no custom domain or certificate for it, so clients
would fail TLS validation. So before users move (phase 5), Classic gets the v2
host name as a second custom domain with the same Key Vault certificate (Classic
Developer allows several, and keeps its existing host name), tested in dev.
Without that, a rollback means every client changes its host name back.

### Phase 7 (later): Premium v2 behind an Application Gateway

- [ ] Public IP exemption for the Application Gateway
- [ ] Template for the injected instance and the Application Gateway; the
  caller-address policy change and its test; TLS policy
- [ ] New dev instance, tests, then prod; key copy and DNS cutover again
- [ ] Remove the Standard v2 instances and the `int` subnet

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

- [x] Outbound through our virtual network to private endpoints (network
  template)
- [ ] Deny outbound Internet on the `int` subnet, once the flows are known
- [ ] `ip-filter` policies kept: with a public gateway and no NSG they are the
  whole inbound lock (stage 2 restores a network-level one)
- [ ] Web application firewall and DDoS protection: not available in stage 1
  (Hermes covers callers that go through it; Azure DDoS Protection is not
  available for the v2 tiers); decide for stage 2 (see "Open questions")

TLS:

- [ ] Platform defaults accepted after a scan (the v2 tiers cannot set
  ciphers); stage 2 sets the Application Gateway TLS policy
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

- Whether the public IP policy blocks Standard v2 (the first dev deployment of
  the gateway shows it), and, for stage 2, whether it can be lifted.
- Whether the Standard v2 instance needs a Key Vault network rule for its
  integration subnet.
- What the platform's default TLS settings accept (phase 3 scan).
- The effect of deny-Internet outbound on the integrated instance (phase 3).
- Whether the PFX in Key Vault serves the intermediate certificates.
- Whether a second Standard v2 unit is billed at the secondary-unit rate.
- For stage 2: a web application firewall on the Application Gateway. Hermes is
  the WAF for callers that go through it, but callers from the NAT pool connect
  directly. The WAF SKU costs about $0.36 an hour fixed against $0.20 for the
  standard one (about $115 more a month per stack), plus a higher
  capacity-unit charge.

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
- Key Vault trusted services and Application Gateway Key Vault certificates
  (`key-vault/general/overview-vnet-service-endpoints`,
  `application-gateway/key-vault-certs`)
- API Management feature comparison and reliability (`api-management/`
  `api-management-features`, `reliability/reliability-api-management`)
- API Management managed identity and Key Vault firewall requirements
  (`api-management/api-management-howto-use-managed-service-identity`)
- Azure Retail Prices API, East US, 2026-11-26
