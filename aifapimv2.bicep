// The gateway of the v2 stacks (aifapimv2 and aifapimv2-dev): API Management Standard v2 in the
// network of aifapimv2-network.bicep, in front of the existing AI Foundry accounts of the
// Classic stack. Plan: APIM_V2_MIGRATION.md.
//
// Only the gateway is created. The Foundry accounts, their model deployments and their quota
// stay where they are; this template adds private endpoints to them in the v2 network, with
// its own private DNS zones, and the roles the gateway identity needs on them. The policies,
// APIs and products are rendered as in aifapim.bicep (the section below is the same text).
//
// Deploy in two steps. The system-assigned identity needs the Key Vault Secrets User role
// before the gateway can read its certificate, and it exists only once the instance does: the
// first deployment leaves apimGatewayHostName empty and grants the role, a second one sets it.
//
// Not in this template yet: the request body log and the Event Hub (see the plan).

@description('Azure region of the gateway and of the private endpoints. It must be the region of the virtual network.')
param location string = resourceGroup().location

@description('Tags to apply to all resources.')
param tags object = {
  'managed-by': 'bicep'
  project: 'aifapim'
  repository: 'NSLS2/aifapim'
}

@description('The name of the API publisher. This information is used by API Management.')
param apiManagementPublisherName string

@description('The email address of the API publisher. This information is used by API Management.')
param apiManagementPublisherEmail string

@description('Display name for the alert email receiver.')
param alertEmailName string

@description('Email address for the alert action group.')
param alertEmailAddress string

@description('Custom gateway (proxy) hostname (e.g., api.example.com). Leave empty to skip.')
param apimGatewayHostName string = ''

@description('Key Vault secret name for the gateway TLS certificate.')
param gatewayKeyVaultSecretName string = ''

@description('Name of the Key Vault containing the TLS certificates for custom domains.')
param keyVaultName string = ''

@description('Resource group of the Key Vault. Defaults to the current resource group.')
param keyVaultResourceGroup string = resourceGroup().name

@description('Put a CanNotDelete lock on this resource group. Updates, key regeneration and deployments still work; deleting anything in the group (a subscription, a named value, a model deployment) needs the lock removed first.')
param lockResourceGroup bool = false

@description('Per-request backend forward-request timeout in seconds applied to all three LLM APIs. Capped at 240 (classic-tier APIM limit).')
@minValue(1)
@maxValue(240)
param backendTimeoutSeconds int = 240

@description('Image requests each caller may make per minute, across all image routes (FLUX, MAI, gpt-image), keyed by subscription or, for a keyless caller, by the token object id. Images carry no tokens, so the token limit does not cover them. Over the limit the gateway answers 429 with Retry-After.')
@minValue(1)
param imageRequestsPerMinute int = 10

@description('Audio transcription requests each caller may make per minute, on the audio route of the Azure OpenAI API (/deployments/{name}/audio/transcriptions), keyed like the image limit. Audio is not counted in tokens here. Over the limit the gateway answers 429 with Retry-After.')
@minValue(1)
param audioRequestsPerMinute int = 10

@description('Host suffix of the model accounts for the Black Forest Labs provider route (FLUX.2-pro). Both are private-endpoint names with a private DNS zone. Microsoft documents api.cognitive.microsoft.com, but that name does not exist for these accounts.')
@allowed([
  'cognitiveservices.azure.com'
  'services.ai.azure.com'
])
param bflEndpointDomain string = 'cognitiveservices.azure.com'

@description('Inbound IP allow-list applied to all three APIM APIs. Each entry is either a single IPv4 address (e.g., "192.0.2.1") or a CIDR range (e.g., "10.0.0.0/16"). CIDR entries are expanded via parseCidr().firstUsable/lastUsable, so the network and broadcast addresses are excluded from the allow-list.')
@minLength(1)
param allowedClientIps array

@description('APIM product name (and App Insights custom-metric namespace). All three APIs are grouped under this product, and the <llm-emit-token-metric> / <emit-metric> policies emit under this namespace. Must be a valid APIM resource name (lowercase alphanumerics + hyphens).')
param apimProductName string = 'aifapim'

@description('Display name for the APIM product (shown in the APIM portal and developer portal).')
param apimProductDisplayName string = 'AIFAPIM'

@description('Description for the APIM product.')
param apimProductDescription string = 'AI Foundry APIM product. Groups the Azure OpenAI, Azure OpenAI v1 Messages, and Anthropic APIs.'

@description('Extra APIM products for service (machine) keys. Each entry is { name, displayName, description, allowedClientIps?, entraAuth? }. Each holds the three inference APIs and the catalog API, like the user product. allowedClientIps (IPv4 addresses, or CIDR ranges taken from the network to the broadcast address) restricts the product to those callers, in addition to the global allowedClientIps. entraAuth ({ tenantId, audience, role }) makes the product need a Microsoft Entra ID app-only access token as well as the key: signed by the tenant, issued for the audience (the client ID of the gateway API app), holding the app role, and obtained with a certificate. open: true makes it the OPEN product: no subscription key is needed, the Entra token alone decides access, from a service principal (the app role, with a certificate) or from a person (a delegated token holding the scope). An open product needs entraAuth { tenantId, audience, role, scope, userRole } (role is the app role for services, scope the delegated scope and userRole the app role a person must hold) and may add clientApplicationIds (client app IDs allowed to ask for a person\'s token); without them it denies every request. An API can be in only one open product, so there is at most one. Keep the real values out of this repository (they belong in the environment parameter file).')
param serviceProducts array = []

@description('Switch for the open (keyless) product. When false, an entry of serviceProducts with open: true is still created, but its policy refuses every request with HTTP 401 OpenProductDisabled, so no request gets in without a subscription key. The product is not deleted (an incremental deployment never deletes it), so switching off always means this refusing policy. Default true.')
param openProductEnabled bool = true

@description('The claude-auto model of the Anthropic API: the gateway rates the request with a small classifier model and rewrites the model to one of three real models. Leave empty to turn it off. Keys, all required when set: classifierModel, simpleModel, mediumModel and complexModel, each the name of a deployment in the primary region. The complex model is also the answer when the classifier fails.')
param claudeAuto object = {}

@description('Curated model catalog JSON array (id/name/provider/context/output per chat-LLM model). Populated in the bicepparam file via loadTextContent(\'./model-catalog.json\'). Baked into the GET /catalog return-response policy at deploy time.')
param catalogJson string

@description('Image model catalog JSON array (id/name/provider/create/edit/routes/residency per image model). Populated in the bicepparam file via loadTextContent(\'./image-catalog.json\'). Baked into the GET /catalog/images return-response policy at deploy time. Kept apart from catalogJson so that clients building a chat model list never see an image model.')
param imageCatalogJson string = '[]'

@description('Embedding model catalog JSON array (id/name/provider/dimensions/max_input_tokens/route/residency per embedding model). Populated in the bicepparam file via loadTextContent(\'./embedding-catalog.json\'). Baked into the GET /catalog/embeddings return-response policy at deploy time. Kept apart from catalogJson because an embedding model has format OpenAI and would be offered to chat clients as a chat model.')
param embeddingCatalogJson string = '[]'

@description('Router catalog JSON array (id/name/provider/context/output/mode/models/routes/residency per model router). Populated in the bicepparam file via loadTextContent(\'./router-catalog.json\'). Baked into the GET /catalog/routers return-response policy at deploy time. Kept apart from catalogJson because a router has format OpenAI but serves Chat Completions only, and chat clients built from catalogJson use the Responses API.')
param routerCatalogJson string = '[]'

@description('Speech-to-text (audio transcription) model catalog JSON array (id/name/provider/max_file_mb/route/residency/timestamps/speaker_labels per model). Populated in the bicepparam file via loadTextContent(\'./transcription-catalog.json\'). Baked into the GET /catalog/transcriptions return-response policy at deploy time.')
param transcriptionCatalogJson string = '[]'

@description('Write one Application Insights trace per request to the five inference APIs that names the caller (the subscription of a key, or the object id of a token caller), with the request id, API, product and model. Join it to ApiManagementGatewayLlmLog on CorrelationId for tokens per caller. Needed for keyless callers of the open product, which have no subscription to name them in the gateway log; harmless for keyed callers.')
param usageTrace bool = false

@description('Name of the virtual network created by aifapimv2-network.bicep, in this resource group.')
param vnetName string

@description('Name of the subnet for the outbound integration of API Management.')
param integrationSubnetName string = 'int'

@description('Name of the subnet for private endpoints.')
param privateEndpointSubnetName string = 'pe'

@description('The existing AI Foundry accounts, each { name, resourceGroup }, in the same order as the regions of the Classic settings: the first is the secondary region (eastus, failover) and the second the primary (eastus2).')
@minLength(2)
@maxLength(2)
param foundryAccounts array

@description('Prefix of the API Management instance name, which is <prefix>-<unique>. A dev prefix with dev in it gives a default host name that the dev smoke test accepts.')
param apimNamePrefix string = 'apim'

@description('Host name clients use to reach the gateway through Front Door, such as aifapimv2-dev.nsls2.bnl.gov. Front Door serves the certificate gatewayKeyVaultSecretName from the vault keyVaultName (RSA, with its intermediates), and the host name must be in it. Leave empty for the first deployment: the Front Door identity needs the Key Vault role first.')
param frontDoorHostName string = ''

@description('Whether the gateway answers on its public address. No default, so every parameter file states it: Enabled only for the bootstrap, Disabled once the Front Door private endpoint connection is approved (APIM refuses to disable it before then, and a deployment that leaves it out resets it to Enabled). The client address check is the same either way.')
@allowed([
  'Enabled'
  'Disabled'
])
param publicNetworkAccess string

@description('Model deployments of each region, as in the Classic settings: the first list is the secondary region (eastus), the second the primary (eastus2). Only the names are used: they decide which models fail over, and which start on the secondary.')
param modelDeployments array


// Client address. Behind Front Door the gateway's connecting address is an internal one, so the
// policies read the address Front Door saw, X-Azure-SocketIP. Front Door overwrites that header when
// a client sends it (tested), unlike X-Forwarded-For and X-Azure-ClientIP, which follow what a
// client writes. The header is trusted only when the connecting address is private (10/8,
// 172.16/12, 192.168/16, 100.64/10), which is how Front Door's Private Link arrives. A direct
// request is judged on its own connecting address, so what the check trusts does not depend on
// publicNetworkAccess. clientAddress is set once, first in the API policy; the global check, the
// product checks and the metrics all read it, and an address that is missing or not IPv4 is refused.
//
// A CIDR entry in the global list covers the usable addresses, in a product list the whole range
// (the NAT pool, all 16 addresses), as in aifapim.bicep.
func ipNumber(ip string) int => int(split(ip, '.')[0]) * 16777216 + int(split(ip, '.')[1]) * 65536 + int(split(ip, '.')[2]) * 256 + int(split(ip, '.')[3])

func clientRangeNumbers(ips array, usable bool) string => join(map(ips, ip => contains(ip, '/')
  ? '${ipNumber(usable ? parseCidr(ip).firstUsable : parseCidr(ip).network)}L, ${ipNumber(usable ? parseCidr(ip).lastUsable : parseCidr(ip).broadcast)}L'
  : '${ipNumber(ip)}L, ${ipNumber(ip)}L'
), ', ')

var clientAddressXml = '<set-variable name="clientAddress" value="@{ var peer = context.Request.IpAddress; if (Regex.IsMatch(peer, &quot;^[0-9]{1,3}([.][0-9]{1,3}){3}$&quot;)) { var o = peer.Split(\'.\'); var a = Convert.ToInt32(o[0]); var b = Convert.ToInt32(o[1]); if (a == 10 || (a == 172 &amp;&amp; b >= 16 &amp;&amp; b &lt;= 31) || (a == 192 &amp;&amp; b == 168) || (a == 100 &amp;&amp; b >= 64 &amp;&amp; b &lt;= 127)) { return context.Request.Headers.GetValueOrDefault(&quot;X-Azure-SocketIP&quot;, &quot;&quot;).Trim(); } } return peer; }" />'

func clientCheckXml(numbers string) string => '<choose><when condition="@{ var ip = (string)context.Variables.GetValueOrDefault(&quot;clientAddress&quot;, &quot;&quot;); if (!Regex.IsMatch(ip, &quot;^[0-9]{1,3}([.][0-9]{1,3}){3}$&quot;)) { return true; } var o = ip.Split(\'.\'); var n = Convert.ToInt64(o[0]) * 16777216L + Convert.ToInt64(o[1]) * 65536L + Convert.ToInt64(o[2]) * 256L + Convert.ToInt64(o[3]); var r = new long[] { ${numbers} }; for (var i = 0; i &lt; r.Length; i += 2) { if (n >= r[i] &amp;&amp; n &lt;= r[i + 1]) { return false; } } return true; }"><return-response><set-status code="403" reason="Forbidden" /></return-response></when></choose>'

func dropIpFilter(xml string) string => replace(replace(xml, '<ip-filter action="allow">', ''), '</ip-filter>', '')

// The policy files wrap their allow-list sentinel in an <ip-filter> element of Classic. Here its tags
// are removed and the sentinel becomes the client address and its check. The metrics dimension that
// the files fill from X-Forwarded-For reads clientAddress instead, because behind Front Door that
// header holds three entries (the client, Front Door, the gateway's own hop). The dimension keeps
// its name, so existing metric queries and workbooks still work.
func v2Policy(xml string) string => replace(dropIpFilter(xml), 'context.Request.Headers.GetValueOrDefault(&quot;X-Forwarded-For&quot;, context.Request.IpAddress)', '(string)context.Variables.GetValueOrDefault(&quot;clientAddress&quot;, context.Request.IpAddress)')

var allowedIpsXml = '${clientAddressXml}${clientCheckXml(clientRangeNumbers(allowedClientIps, true))}'

// The Front Door WAF refuses a list in which an address lies inside a range of the same list, so
// bare addresses covered by a listed CIDR are left out. (Two overlapping CIDRs are not handled.) Every
// conversion sits in a conditional, because ARM's and() and or() do not short-circuit.
func wafAllowList(ips array) array => filter(ips, ip => contains(ip, '/') ? true : length(filter(ips, c => contains(c, '/') ? (ipNumber(ip) >= ipNumber(parseCidr(c).network) && ipNumber(ip) <= ipNumber(parseCidr(c).broadcast)) : false)) == 0)

// The APIM AOAI policy is always the multi-region variant.
// Policies and API definition are loaded from the local repository so deployments do not depend on external URLs.
// Substitutions applied to each policy XML:
//   __BACKEND_TIMEOUT__    -> backendTimeoutSeconds (forward-request timeout)
//   __IMAGE_REQUESTS_PER_MINUTE__ -> imageRequestsPerMinute (per-caller image limit)
//   __AUDIO_REQUESTS_PER_MINUTE__ -> audioRequestsPerMinute (per-caller transcription limit, AOAI policy)
//   __ALLOWED_CLIENT_IPS__ -> allowedIpsXml (client address check built from allowedClientIps)
//   __METRIC_NAMESPACE__   -> apimProductName (App Insights custom-metric namespace)
//   __SECONDARY_MODELS__   -> secondaryModelList (models deployed in the secondary region;
//                             the policies fail over only for these)
//   __SECONDARY_ONLY_MODELS__ -> secondaryOnlyModelList (models in the first region only; the two
//                             OpenAI policies start those requests on the secondary backend)
//   <!-- __REQUEST_LOG__ --> -> inboundLogXml (usage trace and request body log blocks, or nothing)
var secondaryModelList = '|${join(map(modelDeployments[0], d => d.name), '|')}|'
var primaryModelNames = length(modelDeployments) > 1 ? map(modelDeployments[1], d => d.name) : []
var secondaryOnlyModelList = '|${join(map(filter(modelDeployments[0], d => !contains(primaryModelNames, d.name)), d => d.name), '|')}|'

// The inference policies carry the marker comment below in <inbound>. It is replaced by the
// usage trace when usageTrace is true, and by nothing otherwise. The request body log of
// aifapim.bicep is not in the v2 template yet. Applied last, so the fragment is not touched
// by the other substitutions.
var requestLogMarker = '<!-- __REQUEST_LOG__ -->'
// The usage trace (apim_policies/UsageTrace_Fragment.xml) goes in at the marker when
// usageTrace is true.
var usageTraceXml = usageTrace ? loadTextContent('apim_policies/UsageTrace_Fragment.xml') : ''
var inboundLogXml = usageTraceXml
var openApiXml = replace(replace(replace(replace(replace(replace(replace(replace(v2Policy(loadTextContent('apim_policies/AOAI_Policy-Managed_Identity_with_Retry_MultiRegion.xml')), '__BACKEND_TIMEOUT__', string(backendTimeoutSeconds)), '__ALLOWED_CLIENT_IPS__', allowedIpsXml), '__METRIC_NAMESPACE__', apimProductName), '__SECONDARY_MODELS__', secondaryModelList), requestLogMarker, inboundLogXml), '__IMAGE_REQUESTS_PER_MINUTE__', string(imageRequestsPerMinute)), '__AUDIO_REQUESTS_PER_MINUTE__', string(audioRequestsPerMinute)), '__SECONDARY_ONLY_MODELS__', secondaryOnlyModelList)

// Anthropic API policy (multi-region retry variant).
// The claude-auto block (apim_policies/ClaudeAuto_Fragment.xml) replaces the
// marker comment in <inbound> when the claudeAuto parameter is set, and nothing
// otherwise. Applied after the other substitutions, so its own placeholders
// are filled in here and the metric namespace is filled in afterwards.
var claudeAutoMarker = '<!-- __CLAUDE_AUTO__ -->'
var claudeAutoXml = empty(claudeAuto) ? '' : replace(replace(replace(replace(replace(v2Policy(loadTextContent('apim_policies/ClaudeAuto_Fragment.xml')), '__CLAUDE_AUTO_URL__', '${anthropicServiceUrlPrimary}/v1/messages'), '__CLAUDE_AUTO_CLASSIFIER__', claudeAuto.classifierModel), '__CLAUDE_AUTO_SIMPLE__', claudeAuto.simpleModel), '__CLAUDE_AUTO_MEDIUM__', claudeAuto.mediumModel), '__CLAUDE_AUTO_COMPLEX__', claudeAuto.complexModel)
var anthropicApiXml = replace(replace(replace(replace(replace(replace(v2Policy(loadTextContent('apim_policies/Anthropic_Policy-Managed_Identity_with_Retry_MultiRegion.xml')), claudeAutoMarker, claudeAutoXml), '__BACKEND_TIMEOUT__', string(backendTimeoutSeconds)), '__ALLOWED_CLIENT_IPS__', allowedIpsXml), '__METRIC_NAMESPACE__', apimProductName), '__SECONDARY_MODELS__', secondaryModelList), requestLogMarker, inboundLogXml)

// OpenAI v1 Messages API policy (multi-region retry variant).
var openaiV1MessagesApiXml = replace(replace(replace(replace(replace(replace(replace(v2Policy(loadTextContent('apim_policies/OpenAIv1Messages_Policy-Managed_Identity_with_Retry_MultiRegion.xml')), '__BACKEND_TIMEOUT__', string(backendTimeoutSeconds)), '__ALLOWED_CLIENT_IPS__', allowedIpsXml), '__METRIC_NAMESPACE__', apimProductName), '__SECONDARY_MODELS__', secondaryModelList), requestLogMarker, inboundLogXml), '__IMAGE_REQUESTS_PER_MINUTE__', string(imageRequestsPerMinute)), '__SECONDARY_ONLY_MODELS__', secondaryOnlyModelList)

// Black Forest Labs API policy (multi-region retry variant).
var bflApiXml = replace(replace(replace(replace(replace(replace(v2Policy(loadTextContent('apim_policies/BlackForestLabs_Policy-Managed_Identity_with_Retry_MultiRegion.xml')), '__BACKEND_TIMEOUT__', string(backendTimeoutSeconds)), '__ALLOWED_CLIENT_IPS__', allowedIpsXml), '__METRIC_NAMESPACE__', apimProductName), '__SECONDARY_MODELS__', secondaryModelList), requestLogMarker, inboundLogXml), '__IMAGE_REQUESTS_PER_MINUTE__', string(imageRequestsPerMinute))

// MAI image API policy (one backend, no failover: the models are in the secondary region only).
var maiApiXml = replace(replace(replace(replace(replace(v2Policy(loadTextContent('apim_policies/MAI_Image_Policy-Managed_Identity_with_Retry.xml')), '__BACKEND_TIMEOUT__', string(backendTimeoutSeconds)), '__ALLOWED_CLIENT_IPS__', allowedIpsXml), '__METRIC_NAMESPACE__', apimProductName), requestLogMarker, inboundLogXml), '__IMAGE_REQUESTS_PER_MINUTE__', string(imageRequestsPerMinute))

// Catalog API policy: static return-response, no backend.
// Sentinels replaced: __ALLOWED_CLIENT_IPS__ (IP filter), __CATALOG_JSON__ (chat model list
// body), __IMAGE_CATALOG_JSON__ (image model list body), __EMBEDDING_CATALOG_JSON__
// (embedding model list body), __TRANSCRIPTION_CATALOG_JSON__ (speech-to-text model list
// body) and __ROUTER_CATALOG_JSON__ (model router list body).
// The JSON is XML-escaped (& first) because it lands in element text; APIM
// unescapes it, so the response body is the original JSON.
var catalogJsonXml = replace(replace(replace(catalogJson, '&', '&amp;'), '<', '&lt;'), '>', '&gt;')
var embeddingCatalogJsonXml = replace(replace(replace(embeddingCatalogJson, '&', '&amp;'), '<', '&lt;'), '>', '&gt;')
var transcriptionCatalogJsonXml = replace(replace(replace(transcriptionCatalogJson, '&', '&amp;'), '<', '&lt;'), '>', '&gt;')
var routerCatalogJsonXml = replace(replace(replace(routerCatalogJson, '&', '&amp;'), '<', '&lt;'), '>', '&gt;')
var imageCatalogJsonXml = replace(replace(replace(imageCatalogJson, '&', '&amp;'), '<', '&lt;'), '>', '&gt;')
var catalogApiXml = replace(replace(replace(replace(replace(replace(v2Policy(loadTextContent('apim_policies/Catalog_Policy.xml')), '__ALLOWED_CLIENT_IPS__', allowedIpsXml), '__ROUTER_CATALOG_JSON__', routerCatalogJsonXml), '__TRANSCRIPTION_CATALOG_JSON__', transcriptionCatalogJsonXml), '__EMBEDDING_CATALOG_JSON__', embeddingCatalogJsonXml), '__IMAGE_CATALOG_JSON__', imageCatalogJsonXml), '__CATALOG_JSON__', catalogJsonXml)

// Azure OpenAI data-plane inference spec is pinned locally so deployments are
// deterministic and do not depend on github.com being reachable at deploy time.
// Source: https://github.com/Azure/azure-rest-api-specs/blob/main/specification/cognitiveservices/data-plane/AzureOpenAI/inference/stable/2024-10-21/inference.yaml
// Local copy is augmented with /models and /models/{model_id} listing operations.
var openApiSpec = loadTextContent('api_definitions/AzureOpenAI_inference_2024-10-21.yaml')

var apiManagementSkuCount = 1

var openaiApiName = 'azure-openai-service-api'
var openaiApiPath = ''
var openaiApiDisplayName = 'Azure OpenAI Service API'

var openaiV1MessagesApiName = 'azure-openai-v1-messages-api'
var openaiV1MessagesApiPath = 'openai'
var openaiV1MessagesApiDisplayName = 'Azure OpenAI v1 Messages API'

var anthropicApiName = 'anthropic-service-api'
var anthropicApiPath = 'anthropic'
var anthropicApiDisplayName = 'Anthropic Service API'

var bflApiName = 'black-forest-labs-api'
var bflApiPath = 'providers/blackforestlabs/v1'
var bflApiDisplayName = 'Black Forest Labs FLUX API'

var maiApiName = 'mai-image-api'
var maiApiPath = 'mai/v1'
var maiApiDisplayName = 'Microsoft MAI Image API'

var catalogApiName = 'catalog-api'
var catalogApiPath = 'catalog'
var catalogApiDisplayName = 'AIFAPIM Model Catalog API'
var catalogProductName = 'aifapim-catalog'
var catalogProductDisplayName = 'NSLS-II AIF APIM Services (catalog poller)'
var catalogProductDescription = 'Read-only product scoped to GET /catalog only, for the catalog poller service. Keys issued under this product cannot call inference endpoints.'

// Service products: the product-level ip-filter policy is rendered per product
// when it has allowedClientIps. A CIDR entry covers the whole range, network to
// broadcast (unlike the global allow-list, which uses the usable addresses), so
// that every address of the NSLS-II NAT pool, all 16 in use, is accepted.
//
// A product with entraAuth also needs an Entra ID access token (see
// apim_policies/Product_EntraAuth_Policy.xml). Its policy has the same ip-filter
// block when the product has allowedClientIps. The values go into XML, so they
// are escaped.
func xmlEscape(value string) string => replace(replace(replace(replace(replace(value, '&', '&amp;'), '<', '&lt;'), '>', '&gt;'), '"', '&quot;'), '\'', '&apos;')

func productIpFilterXml(ips array) string => empty(ips) ? '' : clientCheckXml(clientRangeNumbers(ips, false))

var productIpPolicyTemplate = v2Policy(loadTextContent('apim_policies/Product_IpRestricted_Policy.xml'))
var productEntraAuthPolicyTemplate = loadTextContent('apim_policies/Product_EntraAuth_Policy.xml')

// The open product needs no subscription key, so its policy is the only access
// check. It accepts people only (services must send key and token, in their own
// product). It is rendered only when entraAuth is complete (tenantId, audience,
// scope and userRole; role is not used); anything less renders a policy that refuses every request, never an
// inheritance-only one, which would leave the product open to anyone. The optional
// clientApplicationIds list is written as client-application-ids in the branch
// that validates a person's token. With openProductEnabled false the open product
// gets a policy that refuses every request instead (401 OpenProductDisabled).
var productEntraOpenPolicyTemplate = loadTextContent('apim_policies/Product_EntraOpen_Policy.xml')
var productOpenDisabledPolicyXml = '<policies><inbound><base /><return-response><set-status code="401" reason="Unauthorized" /><set-header name="Content-Type" exists-action="override"><value>application/json</value></set-header><set-body>{"error":{"code":"OpenProductDisabled","message":"Keyless access is switched off on this gateway. Send a subscription key in the x-api-key header."}}</set-body></return-response></inbound><backend><base /></backend><outbound><base /></outbound><on-error><base /></on-error></policies>'
var productDenyAllPolicyXml = '<policies><inbound><base /><return-response><set-status code="503" reason="Service Unavailable" /><set-header name="Content-Type" exists-action="override"><value>application/json</value></set-header><set-body>{"error":{"code":"ProductNotConfigured","message":"This product is open but its Entra ID settings are incomplete."}}</set-body></return-response></inbound><backend><base /></backend><outbound><base /></outbound><on-error><base /></on-error></policies>'
func entraOpenComplete(e object) bool => !empty(e.?tenantId ?? '') && !empty(e.?audience ?? '') && !empty(e.?scope ?? '') && !empty(e.?userRole ?? '')
func clientAppsXml(ids array) string => empty(ids) ? '' : '<client-application-ids>\n                        ${join(map(ids, id => '<application-id>${replace(replace(replace(replace(replace(id, '&', '&amp;'), '<', '&lt;'), '>', '&gt;'), '"', '&quot;'), '\'', '&apos;')}</application-id>'), '\n                        ')}\n                    </client-application-ids>'
var serviceProductsResolved = map(serviceProducts, p => {
  name: p.name
  displayName: p.displayName
  description: p.description
  open: p.?open ?? false
  policyXml: (p.?open ?? false)
    ? !openProductEnabled
      ? productOpenDisabledPolicyXml
      : (entraOpenComplete(p.?entraAuth ?? {})
        ? replace(replace(replace(replace(replace(replace(productEntraOpenPolicyTemplate, '__PRODUCT_IP_FILTER__', productIpFilterXml(p.?allowedClientIps ?? [])), '__ENTRA_CLIENT_APPS__', clientAppsXml(p.entraAuth.?clientApplicationIds ?? [])), '__ENTRA_TENANT_ID__', xmlEscape(p.entraAuth.tenantId)), '__ENTRA_AUDIENCE__', xmlEscape(p.entraAuth.audience)), '__ENTRA_SCOPE__', xmlEscape(p.entraAuth.scope)), '__ENTRA_USER_ROLE__', xmlEscape(p.entraAuth.userRole))
        : productDenyAllPolicyXml)
    : !empty(p.?entraAuth ?? {})
    ? replace(replace(replace(replace(productEntraAuthPolicyTemplate, '__PRODUCT_IP_FILTER__', productIpFilterXml(p.?allowedClientIps ?? [])), '__ENTRA_TENANT_ID__', xmlEscape(p.entraAuth.tenantId)), '__ENTRA_AUDIENCE__', xmlEscape(p.entraAuth.audience)), '__ENTRA_ROLE__', xmlEscape(p.entraAuth.role))
    : empty(p.?allowedClientIps ?? []) ? '' : replace(productIpPolicyTemplate, '__PRODUCT_ALLOWED_IPS__', clientCheckXml(clientRangeNumbers(p.allowedClientIps, false)))
})

var unique = uniqueString(resourceGroup().id, subscription().id)
var apiManagementServiceName = '${apimNamePrefix}-${unique}'
var logAnalyticsName = 'law-${unique}'
var applicationInsightsName = 'appIn-${unique}'

var azureRoles = loadJsonContent('azure_roles.json')

resource vnet 'Microsoft.Network/virtualNetworks@2023-11-01' existing = {
  name: vnetName
}

var integrationSubnetId = resourceId('Microsoft.Network/virtualNetworks/subnets', vnetName, integrationSubnetName)
var privateEndpointSubnetId = resourceId('Microsoft.Network/virtualNetworks/subnets', vnetName, privateEndpointSubnetName)

// AI Services accounts expose three host names and need all three zones, linked to this
// network. They are this stack's own zones: two private endpoints for one account cannot
// share a zone, and the Classic zones are linked to the Classic networks.
var aiPrivateDnsZoneNames = [
  'privatelink.openai.azure.com'
  'privatelink.cognitiveservices.azure.com'
  'privatelink.services.ai.azure.com'
]

module aiPrivateDnsZones 'modules/private-dns-zone.bicep' = [for zoneName in aiPrivateDnsZoneNames: {
  name: replace(zoneName, '.', '-')
  params: {
    zoneName: zoneName
    vnetId: vnet.id
    tags: tags
  }
}]

module foundryEndpoints 'modules/foundry-private-endpoint.bicep' = [for (account, i) in foundryAccounts: {
  name: 'foundry-pe-${i}'
  params: {
    location: location
    accountName: account.name
    accountResourceGroup: account.resourceGroup
    subnetId: privateEndpointSubnetId
    privateDnsZoneIds: [for z in range(0, length(aiPrivateDnsZoneNames)): aiPrivateDnsZones[z].outputs.zoneId]
    tags: tags
  }
}]

// Primary backend: the second account (eastus2). The retry and failover policies fall back to
// the first (eastus) on errors.
var apiServiceNamePrimary string = foundryAccounts[1].name
var apiServiceNameSecondary string = foundryAccounts[0].name
var apiServiceUrlPrimary = 'https://${apiServiceNamePrimary}.openai.azure.com/openai'
var apiServiceUrlSecondary = 'https://${apiServiceNameSecondary}.openai.azure.com/openai'
var anthropicServiceUrlPrimary = 'https://${apiServiceNamePrimary}.services.ai.azure.com/anthropic'
var anthropicServiceUrlSecondary = 'https://${apiServiceNameSecondary}.services.ai.azure.com/anthropic'
var bflServiceUrlPrimary = 'https://${apiServiceNamePrimary}.${bflEndpointDomain}/providers/blackforestlabs/v1'
var bflServiceUrlSecondary = 'https://${apiServiceNameSecondary}.${bflEndpointDomain}/providers/blackforestlabs/v1'
var maiServiceUrl = 'https://${apiServiceNameSecondary}.services.ai.azure.com/mai/v1'

module logAnalyticsWorkspace 'modules/log-analytics-workspace.bicep' = {
  name: 'log-analytics-workspace'
  params: {
    location: location
    logAnalyticsName: logAnalyticsName
    tags: tags
  }
}

module applicationInsights 'modules/app-insights.bicep' = {
  name: 'application-insights'
  params: {
    location: location
    workspaceName: logAnalyticsName
    applicationInsightsName: applicationInsightsName
    uniqueSuffix: unique
    alertEmailName: alertEmailName
    alertEmailAddress: alertEmailAddress
    tags: tags
  }
  dependsOn: [
    logAnalyticsWorkspace
  ]
}

// LLM-aware latency alerts (scheduled-query rules on ApiManagementGatewayLogs).
module llmLatencyAlerts 'modules/llm-latency-alerts.bicep' = {
  name: 'llm-latency-alerts'
  params: {
    location: location
    workspaceResourceId: logAnalyticsWorkspace.outputs.id
    actionGroupId: applicationInsights.outputs.actionGroupId
    uniqueSuffix: unique
    // The table of the gateway logs does not exist in a new workspace until the gateway has
    // sent its first logs, and the rules cannot be created while it is missing.
    skipQueryValidation: true
    tags: tags
  }
}

module apiManagement 'modules/api-management-v2.bicep' = {
  name: 'api-management'
  params: {
    location: location
    serviceName: apiManagementServiceName
    publisherName: apiManagementPublisherName
    publisherEmail: apiManagementPublisherEmail
    skuCount: apiManagementSkuCount
    publicNetworkAccess: publicNetworkAccess
    subnetResourceId: integrationSubnetId
    aiName: applicationInsightsName
    gatewayHostName: apimGatewayHostName
    keyVaultName: keyVaultName
    gatewayKeyVaultSecretName: gatewayKeyVaultSecretName
    logAnalyticsWorkspaceId: logAnalyticsWorkspace.outputs.id
    tags: tags
  }
  dependsOn: [
    applicationInsights
  ]
}

// Front Door is the public entry. Its endpoint is named like the gateway, so a dev prefix with dev
// in it gives a Front Door address with dev in it, which test-models.py needs to take it as dev. Its
// Private Link request on the gateway has to be approved by hand (see modules/front-door.bicep), and
// only then can publicNetworkAccess be set to Disabled.
module frontDoor 'modules/front-door.bicep' = {
  name: 'front-door'
  params: {
    profileName: 'afd-${unique}'
    endpointName: '${apimNamePrefix}-${unique}'
    wafPolicyName: 'waf${unique}'
    apimId: apimServiceRef.id
    apimHostName: apiManagement.outputs.apiManagementDefaultHostName
    apimLocation: location
    allowedClientIps: wafAllowList(allowedClientIps)
    logAnalyticsWorkspaceId: logAnalyticsWorkspace.outputs.id
    customDomainHostName: frontDoorHostName
    certificateSourceId: empty(keyVaultName) ? '' : resourceId(subscription().subscriptionId, keyVaultResourceGroup, 'Microsoft.KeyVault/vaults/secrets', keyVaultName, gatewayKeyVaultSecretName)
    tags: tags
  }
}

// Front Door reads the certificate with its own identity, which belongs to the profile, so the role is
// written after the Front Door module. The secret and the domain only appear when frontDoorHostName
// is set, in a second deployment, once the role is in place (as for the gateway's own domain).
module frontDoorKeyVaultAccess 'modules/keyvault-role.bicep' = if (!empty(keyVaultName)) {
  name: 'kvSecretUserForFrontDoor'
  scope: resourceGroup(keyVaultResourceGroup)
  params: {
    keyVaultName: keyVaultName
    roleName: guid(subscription().id, keyVaultName, 'afd-${unique}', 'KeyVaultSecretUser', 'system-assigned')
    principalId: frontDoor.outputs.identityPrincipalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: resourceId('Microsoft.Authorization/roleDefinitions', '4633458b-17de-408a-b874-0445c86b69e6') // Key Vault Secrets User
  }
}

resource apimServiceRef 'Microsoft.ApiManagement/service@2024-05-01' existing = {
  name: apiManagementServiceName
  dependsOn: [
    apiManagement
  ]
}

// The built-in all-access subscription (master) is scoped to the whole service, so its keys skip
// every product policy, including the Entra token check of the agent products. A template cannot
// suspend it: APIM answers a write with "Can't modify global subscription". It is suspended by
// hand after the first deployment (docs/apim-v2-migration.md in aifapim-config).

// The system-assigned identity exists only once APIM does, so this role is written after the
// APIM module. Only a custom domain on the gateway itself needs it (see the header); with the
// host name on Front Door the gateway reads no certificate and gets no role on the vault.
module kvAccess 'modules/keyvault-role.bicep' = if (!empty(keyVaultName) && !empty(apimGatewayHostName)) {
  name: 'kvSecretUserForApimSystem'
  scope: resourceGroup(keyVaultResourceGroup)
  params: {
    keyVaultName: keyVaultName
    roleName: guid(subscription().id, keyVaultName, apiManagementServiceName, 'KeyVaultSecretUser', 'system-assigned')
    principalId: apiManagement.outputs.apiManagementIdentityPrincipalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: resourceId('Microsoft.Authorization/roleDefinitions', '4633458b-17de-408a-b874-0445c86b69e6') // Key Vault Secrets User
  }
}

module api 'modules/api.bicep' = {
  name: 'api'
  params: {
    apimName: apiManagementServiceName
    apiName: openaiApiName
    apiPath: openaiApiPath
    openaiApiDisplayName: openaiApiDisplayName
    openApiSpec: openApiSpec
    openApiXml : openApiXml
    openaiV1MessagesApiXml: openaiV1MessagesApiXml
    openaiV1MessagesApiName: openaiV1MessagesApiName
    openaiV1MessagesApiPath: openaiV1MessagesApiPath
    openaiV1MessagesApiDisplayName: openaiV1MessagesApiDisplayName
    openaiV1MessagesOpenApiSpec: loadTextContent('api_definitions/AzureOpenAI_v1_Messages_OpenAPI.json')
    anthropicApiXml: anthropicApiXml
    anthropicApiName: anthropicApiName
    anthropicApiPath: anthropicApiPath
    anthropicApiDisplayName: anthropicApiDisplayName
    anthropicOpenApiSpec: loadTextContent('api_definitions/AzureAnthropic_OpenAPI.json')
    serviceUrlPrimary : apiServiceUrlPrimary
    serviceUrlSecondary: apiServiceUrlSecondary
    anthropicServiceUrlPrimary: anthropicServiceUrlPrimary
    anthropicServiceUrlSecondary: anthropicServiceUrlSecondary
    bflServiceUrlPrimary: bflServiceUrlPrimary
    bflServiceUrlSecondary: bflServiceUrlSecondary
    bflApiName: bflApiName
    bflApiPath: bflApiPath
    bflApiDisplayName: bflApiDisplayName
    bflApiXml: bflApiXml
    bflOpenApiSpec: loadTextContent('api_definitions/BlackForestLabs_OpenAPI.json')
    maiServiceUrl: maiServiceUrl
    maiApiName: maiApiName
    maiApiPath: maiApiPath
    maiApiDisplayName: maiApiDisplayName
    maiApiXml: maiApiXml
    maiOpenApiSpec: loadTextContent('api_definitions/MAI_Image_OpenAPI.json')
    aiLoggerId: apiManagement.outputs.aiLoggerId
    apimProductName: apimProductName
    apimProductDisplayName: apimProductDisplayName
    apimProductDescription: apimProductDescription
    catalogApiName: catalogApiName
    catalogApiPath: catalogApiPath
    catalogApiDisplayName: catalogApiDisplayName
    catalogApiXml: catalogApiXml
    catalogOpenApiSpec: loadTextContent('api_definitions/Catalog_OpenAPI.json')
    catalogProductName: catalogProductName
    catalogProductDisplayName: catalogProductDisplayName
    catalogProductDescription: catalogProductDescription
    serviceProducts: serviceProductsResolved
  }
}

// Monitoring Metrics Publisher on App Insights, so the custom token metrics appear.
resource appInsightsRef 'Microsoft.Insights/components@2020-02-02' existing = {
  name: applicationInsightsName
}

resource apimMetricsPublisher 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(subscription().id, resourceGroup().id, applicationInsightsName, 'MonitoringMetricsPublisher')
  scope: appInsightsRef
  properties: {
    principalId: apiManagement.outputs.apiManagementIdentityPrincipalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: resourceId('Microsoft.Authorization/roleDefinitions', azureRoles.MonitoringMetricsPublisher)
  }
  dependsOn: [
    applicationInsights
  ]
}

// Cognitive Services OpenAI User on each existing AI Foundry account.
module openAiRoles 'modules/cognitive-services-role.bicep' = [for (account, i) in foundryAccounts: {
  name: 'openai-roles-${i}'
  scope: resourceGroup(account.resourceGroup)
  params: {
    accountName: account.name
    principalId: apiManagement.outputs.apiManagementIdentityPrincipalId
    roleDefinitionId: resourceId('Microsoft.Authorization/roleDefinitions', azureRoles.CognitiveServicesOpenAIUser)
  }
}]

// Azure AI User on each account: non-OpenAI providers exposed through AI Services (for example
// Anthropic /anthropic/*) need the AIServices/providers/action data action.
module aiUserRoles 'modules/cognitive-services-role.bicep' = [for (account, i) in foundryAccounts: {
  name: 'ai-user-roles-${i}'
  scope: resourceGroup(account.resourceGroup)
  params: {
    accountName: account.name
    principalId: apiManagement.outputs.apiManagementIdentityPrincipalId
    roleDefinitionId: resourceId('Microsoft.Authorization/roleDefinitions', azureRoles.AzureAIUser)
  }
}]

resource protect 'Microsoft.Authorization/locks@2020-05-01' = if (lockResourceGroup) {
  name: 'protect-${resourceGroup().name}'
  properties: {
    level: 'CanNotDelete'
    notes: 'Remove the lock to delete anything in this group, then add it again (deploy with lockResourceGroup true).'
  }
}

output apiManagementName string = apiManagementServiceName
output frontDoorEndpointHostName string = frontDoor.outputs.endpointHostName
output apiManagementDefaultHostName string = apiManagement.outputs.apiManagementDefaultHostName
