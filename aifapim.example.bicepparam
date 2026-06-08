using 'aifapim.bicep'

// =============================================================================
// AIF APIM example parameter file.
//
// Copy this file to e.g. aifapim-prod.bicepparam or aifapim-dev.bicepparam,
// replace the placeholder values below with your environment-specific
// settings, then deploy with:
//
//     az deployment group create \
//       --resource-group <your-rg> \
//       --template-file aifapim.bicep \
//       --parameters <your-env>.bicepparam
//
// Real (non-example) *.bicepparam files are gitignored; see .gitignore.
// =============================================================================

// ---- APIM SKU ----
// One of: 'Developer', 'BasicV2', 'StandardV2', 'Premium'.
// 'Developer' is the classic tier used for non-production; v2 tiers and
// 'Premium' support different feature sets (see README "Platform behaviors").
param apiManagementSku = 'Developer'

// ---- Networking ----
// APIM subnet CIDR. Must lie inside regions[0].vnetAddressPrefix below
// (the APIM subnet is added to regions[0]'s VNet).
param apiManagementSubnetIPPrefix = '10.10.2.0/24'

// ---- Publisher metadata (shown in APIM portal + emails) ----
param apiManagementPublisherName  = '<Your Organization>'
param apiManagementPublisherEmail = 'apim-admin@example.com'

// ---- Alert action group recipient ----
param alertEmailName    = '<Your Org> AIF APIM Alerts'
param alertEmailAddress = 'alerts@example.com'

// ---- Custom domain (TLS via Key Vault) ----
// Leave apimGatewayHostName empty to skip custom-domain wiring entirely.
param apimGatewayHostName       = 'api.example.com'
param gatewayKeyVaultSecretName = '<kv-secret-name-for-gateway-cert>'

// ---- Key Vault holding the TLS certificate secrets ----
// The Key Vault must be RBAC-enabled and contain the gateway cert stored as
// a *secret* (not a certificate). The deployment grants the APIM user-
// assigned managed identity 'Key Vault Secrets User' on this vault before
// APIM is created (solves the chicken-and-egg problem at deploy time).
param keyVaultName          = '<your-kv-name>'
param keyVaultResourceGroup = '<your-kv-resource-group>'

// ---- Optional CA certificates added to the APIM cert store ----
// PEM-encoded intermediate / root CA certs to add to APIM's CertificateAuthority
// and Root stores, respectively. Both default to empty (skip).
//
// loadTextContent() runs at bicepparam compile time, so the file paths are
// resolved relative to this .bicepparam file. The bundled resources/ directory
// is gitignored aside from a .gitkeep; place your PEM files there (or any path
// you prefer) and uncomment the matching line below.
//
// param intermediateCaCert = loadTextContent('resources/<your-intermediate>.pem')
// param rootCaCert         = loadTextContent('resources/<your-root>.pem')

// ---- Anthropic provider attestation ----
// Required by Anthropic for Anthropic-format model deployments on Azure AI
// Foundry. These values are sent to Anthropic with the deployment metadata.
param anthropicIndustry         = 'Technology'
param anthropicCountryCode      = 'US'   // ISO 3166-1 alpha-2
param anthropicOrganizationName = '<Your Organization>'

// ---- Default model capacities (TPM) ----
// Overridable per-entry in modelDeployments via the optional `capacity` key.
param openaiCapacity    = 100
param anthropicCapacity = 100

// ---- Per-request backend timeout (seconds) ----
// Capped at 240 on classic-tier APIM.
param backendTimeoutSeconds = 240

// ---- APIM product ----
// All three APIs (azure-openai-service-api, azure-openai-v1-messages-api,
// anthropic-service-api) are grouped under this product. The same value is
// also used as the App Insights custom-metric namespace by the
// <llm-emit-token-metric> and <emit-metric> policies, so queries against
// AppMetrics filter by this namespace. Must be a valid APIM resource name
// (lowercase alphanumerics + hyphens).
param apimProductName        = 'aifapim'
param apimProductDisplayName = 'AIFAPIM'
param apimProductDescription = 'AI Foundry APIM product. Groups the Azure OpenAI, Azure OpenAI v1 Messages, and Anthropic APIs.'

// ---- Anthropic model name alias map ----
// Maps client-supplied Anthropic model names to the canonical deployment names
// that AI Foundry recognises. The map is baked into the Anthropic API policy
// (anthropic-service-api) at deploy time (via the __MODEL_ALIAS_MAP__ sentinel)
// and applied in the inbound phase before the request is forwarded to the
// backend. The OpenAI APIs are unaffected — OpenAI clients do not send
// date-postfixed names.
//
// Primary use-case: Anthropic appends date postfixes to model identifiers
// when they release new Claude versions (e.g. "claude-sonnet-4-6-20251114").
// Claude Code and other Anthropic SDK clients send these versioned names
// verbatim. Without the alias map the request reaches Foundry with a name
// that does not match any deployment resource and returns 404, causing the
// retry loop to exhaust both regions and fail the request entirely.
//
// Each entry must have:
//   from  - the exact Anthropic model string the client sends
//   to    - the deployment resource name in AI Foundry (must match a `name`
//           entry in modelDeployments above)
//
// Omit entries whose `from` and `to` values are identical — they are
// unnecessary no-ops and add minor compile-time overhead.
//
// The entries below cover every date-postfixed model ID found in Claude Code
// v2.1.152 (inspected via:
//   strings /opt/claude-code/bin/claude | grep -oE 'claude-[a-z]+-[0-9](-[0-9]+)?-[0-9]{8}' | sort -u
// ). Entries whose `to` value does not match any name in your modelDeployments
// array above are silently ignored at runtime (the dictionary lookup simply
// never matches), so it is safe to include the full list even if you have not
// deployed every model. Remove or comment out entries only if you want to
// deliberately block a specific versioned name from resolving.
//
// When a new Claude Code release introduces additional date-postfixed IDs,
// add them here and redeploy. No change to modelDeployments is required.
param anthropicModelAliases = [
  // claude-sonnet-4-6-20251114 is the versioned ID Claude Code sends for
  // the current default model (claude-sonnet-4-6) as of v2.1.152.
  { from: 'claude-sonnet-4-6-20251114', to: 'claude-sonnet-4-6' }
  { from: 'claude-sonnet-4-5-20250929', to: 'claude-sonnet-4-5' }
  { from: 'claude-haiku-4-5-20251001',  to: 'claude-haiku-4-5'  }
  { from: 'claude-opus-4-6-20251101',   to: 'claude-opus-4-6'   }
  { from: 'claude-opus-4-5-20251101',   to: 'claude-opus-4-5'   }
  { from: 'claude-opus-4-1-20250805',   to: 'claude-opus-4-1'   }
  // Deprecated generation-only IDs (claude-opus-4-0 / claude-sonnet-4-0).
  // Safe to leave in; they will no-op if those deployments don't exist.
  { from: 'claude-opus-4-20250514',   to: 'claude-opus-4-0'   }
  { from: 'claude-sonnet-4-20250514', to: 'claude-sonnet-4-0' }
]

// ---- Inbound IP allow-list ----
// Applied to all three APIM APIs. Entries are either a single IPv4 address
// or a CIDR range. CIDR entries are expanded via parseCidr().firstUsable/
// lastUsable, so the network and broadcast addresses are excluded.
// An empty list is rejected at deploy time (@minLength(1)).
//
// The values below are RFC 5737 documentation IPs — they cannot route real
// traffic. Replace with your actual client IPs/ranges before deploying.
param allowedClientIps = [
  '192.0.2.10'         // example single IPv4 (TEST-NET-1)
  '198.51.100.0/24'    // example /24 (TEST-NET-2)
  '203.0.113.0/24'     // example /24 (TEST-NET-3)
]

// ---- Regions ----
// Two-region multi-region deployment. regions[1] is the *primary* backend;
// regions[0] is the failover. vnetAddressPrefix and openAiSubnetPrefix must
// not overlap between regions (the two VNets are peered).
param regions = [
  {
    name: 'eastus'
    label: 'eus'
    vnetAddressPrefix:  '10.10.0.0/16'
    openAiSubnetPrefix: '10.10.0.0/24'
  }
  {
    name: 'eastus2'
    label: 'eus2'
    vnetAddressPrefix:  '10.11.0.0/16'
    openAiSubnetPrefix: '10.11.0.0/24'
  }
]

// ---- Model deployments (per region) ----
// Outer array index aligns with `regions[*]` (so modelDeployments[0]
// targets regions[0], modelDeployments[1] targets regions[1]).
//
// Each entry's keys:
//   name      - APIM-facing deployment name (what clients pass as `model`)
//   model     - Azure AI Foundry model id
//   version   - model version
//   skuName   - 'DataZoneStandard' (OpenAI/Foundry) | 'GlobalStandard' (most others)
//   capacity  - (optional) per-deployment TPM, overrides openai/anthropicCapacity
//   format    - (optional) 'Anthropic' | 'Meta' — required for non-OpenAI families
//
// Anthropic models are only offered by Foundry in select regions (currently
// eastus2); leave them out of regions[0] if that region cannot host them.
param modelDeployments = [
  // ---- regions[0] (failover) ----
  [
    {
      name:    'gpt-4.1-mini'
      model:   'gpt-4.1-mini'
      version: '2025-04-14'
      skuName: 'DataZoneStandard'
    }
    {
      name:    'Llama-3.3-70B-Instruct'
      model:   'Llama-3.3-70B-Instruct'
      version: '1'
      skuName: 'GlobalStandard'
      capacity: 1
      format:  'Meta'
    }
  ]
  // ---- regions[1] (primary) ----
  [
    {
      name:    'gpt-4.1-mini'
      model:   'gpt-4.1-mini'
      version: '2025-04-14'
      skuName: 'DataZoneStandard'
    }
    {
      name:    'claude-sonnet-4-5'
      model:   'claude-sonnet-4-5'
      version: '20250929'
      skuName: 'GlobalStandard'
      format:  'Anthropic'
    }
    {
      name:    'Llama-3.3-70B-Instruct'
      model:   'Llama-3.3-70B-Instruct'
      version: '1'
      skuName: 'GlobalStandard'
      capacity: 1
      format:  'Meta'
    }
  ]
]
