@description('The location into which the API Management resources should be deployed.')
param location string

@description('The name of the API Management service instance to create. This must be globally unique.')
param serviceName string

@description('The name of the API publisher. This information is used by API Management.')
param publisherName string

@description('The email address of the API publisher. This information is used by API Management.')
param publisherEmail string

param aiName string

@description('The name of the SKU to use when creating the API Management service instance. This must be a SKU that supports virtual network integration.')
param skuName string

@description('The number of worker instances of your API Management service that should be provisioned.')
param skuCount int

param virtualNetworkType string

param subnetResourceId string

@description('Custom gateway hostname (e.g., api.example.com). Leave empty to skip.')
param gatewayHostName string = ''

@description('Custom developer portal hostname. Leave empty to skip.')
param portalHostName string = ''

@description('Name of the Key Vault containing TLS certificates.')
param keyVaultName string = ''

@description('Resource group of the Key Vault.')
#disable-next-line no-unused-params
param keyVaultResourceGroup string = ''

@description('Key Vault secret name for the gateway TLS certificate.')
param gatewayKeyVaultSecretName string = ''

@description('Key Vault secret name for the developer portal TLS certificate.')
param portalKeyVaultSecretName string = ''

@description('PEM-encoded intermediate CA certificate.')
param intermediateCaCert string = ''

@description('PEM-encoded root CA certificate.')
param rootCaCert string = ''

@description('Resource ID of a user-assigned managed identity for Key Vault access. Leave empty if not using custom domains.')
param userAssignedIdentityId string = ''

@description('Client ID of the user-assigned managed identity that reads the custom-domain certificates from Key Vault. Leave empty to use the system-assigned identity, which a Key Vault firewall requires.')
param userAssignedIdentityClientId string = ''

@description('Disable the developer portal entirely.')
param disableDeveloperPortal bool = true

@description('Resource ID of the Log Analytics workspace to receive APIM diagnostic logs (incl. generative AI gateway / LLM logs). Leave empty to skip.')
param logAnalyticsWorkspaceId string = ''
param tags object = {}

var enableCustomDomains = !empty(gatewayHostName) && !empty(gatewayKeyVaultSecretName)
var enablePortalDomain = !empty(portalHostName) && !empty(portalKeyVaultSecretName)
var keyVaultBaseUrl = 'https://${keyVaultName}${environment().suffixes.keyvaultDns}'

var defaultHostnameConfig = [
  {
    type: 'Proxy'
    hostName: '${serviceName}.azure-api.net'
    negotiateClientCertificate: false
    defaultSslBinding: !enableCustomDomains
  }
]

var gatewayHostnameConfig = enableCustomDomains ? [
  {
    type: 'Proxy'
    hostName: gatewayHostName
    negotiateClientCertificate: false
    defaultSslBinding: true
    keyVaultId: '${keyVaultBaseUrl}/secrets/${gatewayKeyVaultSecretName}'
    identityClientId: empty(userAssignedIdentityClientId) ? null : userAssignedIdentityClientId
  }
] : []

var portalHostnameConfig = enablePortalDomain ? [
  {
    type: 'DeveloperPortal'
    hostName: portalHostName
    negotiateClientCertificate: false
    keyVaultId: '${keyVaultBaseUrl}/secrets/${portalKeyVaultSecretName}'
    identityClientId: empty(userAssignedIdentityClientId) ? null : userAssignedIdentityClientId
  }
] : []

var hostnameConfigurations = concat(defaultHostnameConfig, gatewayHostnameConfig, portalHostnameConfig)

var intermediateCaCerts = !empty(intermediateCaCert) ? [
  {
    encodedCertificate: replace(replace(replace(intermediateCaCert, '-----BEGIN CERTIFICATE-----', ''), '-----END CERTIFICATE-----', ''), '\n', '')
    storeName: 'CertificateAuthority'
  }
] : []

var rootCaCerts = !empty(rootCaCert) ? [
  {
    encodedCertificate: replace(replace(replace(rootCaCert, '-----BEGIN CERTIFICATE-----', ''), '-----END CERTIFICATE-----', ''), '\n', '')
    storeName: 'Root'
  }
] : []

var certificates = concat(intermediateCaCerts, rootCaCerts)

resource aiParent 'Microsoft.Insights/components@2020-02-02-preview' existing = {
  name: aiName
}
resource apiManagementService 'Microsoft.ApiManagement/service@2023-03-01-preview' = {
  name: serviceName
  location: location
  tags: tags
  sku: {
    name: skuName
    capacity: skuCount
  }
  identity: {
    type: !empty(userAssignedIdentityId) ? 'SystemAssigned, UserAssigned' : 'SystemAssigned'
    userAssignedIdentities: !empty(userAssignedIdentityId) ? {
      '${userAssignedIdentityId}': {}
    } : null
  }
  properties: {
    publisherName: publisherName
    publisherEmail: publisherEmail
    virtualNetworkConfiguration: {
      subnetResourceId: subnetResourceId
    }
    virtualNetworkType: virtualNetworkType
    hostnameConfigurations: hostnameConfigurations
    certificates: certificates
    developerPortalStatus: disableDeveloperPortal ? 'Disabled' : 'Enabled'
    // Pin properties that ARM would otherwise force-modify on every deploy.
    // On Developer SKU (single unit) any service-level mutation transitions
    // the instance and races the child API/policy writes from api.bicep,
    // producing `ServiceLocked: The API Service is transitioning at this
    // time` on classic-tier deploys. Pin to the platform-default live values
    // so the service write is a no-op. natGatewayState is intentionally NOT
    // pinned: live value is the read-only `Unsupported` state on Developer
    // SKU and supplying it as input risks rejection. See AGENTS.md
    // "Developer SKU ServiceLocked race".
    publicNetworkAccess: 'Enabled'
    legacyPortalStatus: 'Disabled'
    customProperties: {
      'Microsoft.WindowsAzure.ApiManagement.Gateway.Protocols.Server.Http2': 'true'
      // Disable weak/deprecated ciphers and TLS protocols (Azure.APIM.Ciphers)
      'Microsoft.WindowsAzure.ApiManagement.Gateway.Security.Ciphers.TripleDes168': 'false'
      'Microsoft.WindowsAzure.ApiManagement.Gateway.Security.Ciphers.TLS_RSA_WITH_AES_128_CBC_SHA': 'false'
      'Microsoft.WindowsAzure.ApiManagement.Gateway.Security.Ciphers.TLS_RSA_WITH_AES_256_CBC_SHA': 'false'
      'Microsoft.WindowsAzure.ApiManagement.Gateway.Security.Ciphers.TLS_RSA_WITH_AES_128_CBC_SHA256': 'false'
      'Microsoft.WindowsAzure.ApiManagement.Gateway.Security.Ciphers.TLS_RSA_WITH_AES_256_CBC_SHA256': 'false'
      'Microsoft.WindowsAzure.ApiManagement.Gateway.Security.Ciphers.TLS_ECDHE_RSA_WITH_AES_256_CBC_SHA': 'false'
      'Microsoft.WindowsAzure.ApiManagement.Gateway.Security.Ciphers.TLS_ECDHE_RSA_WITH_AES_128_CBC_SHA': 'false'
      'Microsoft.WindowsAzure.ApiManagement.Gateway.Security.Ciphers.TLS_RSA_WITH_AES_128_GCM_SHA256': 'false'
      'Microsoft.WindowsAzure.ApiManagement.Gateway.Security.Protocols.Tls10': 'false'
      'Microsoft.WindowsAzure.ApiManagement.Gateway.Security.Protocols.Tls11': 'false'
      'Microsoft.WindowsAzure.ApiManagement.Gateway.Security.Protocols.Ssl30': 'false'
    }
    apiVersionConstraint: {
      // Require control-plane API version >= 2021-08-01 (Azure.APIM.MinAPIVersion)
      minApiVersion: '2021-08-01'
    }
  }
}

// APIM keeps a logger's identityClientId in a secret named value and writes a new
// one ("Logger-Credentials--<id>") on every deployment that writes the logger, so
// they piled up (51 on prod, 88 on dev). The value is only the word systemAssigned,
// not a secret: App Insights has local authentication off, so the connection string
// alone cannot send telemetry. Give the logger one plain named value of our own.
resource aiLoggerIdentity 'Microsoft.ApiManagement/service/namedValues@2023-03-01-preview' = {
  parent: apiManagementService
  name: 'ai-logger-identity'
  properties: {
    displayName: 'ai-logger-identity'
    value: 'systemAssigned'
    secret: false
  }
}

resource aiLoggerWithSystemAssignedIdentity 'Microsoft.ApiManagement/service/loggers@2022-08-01' = {
  name: 'aiLoggerWithSystemAssignedIdentity'
  parent: apiManagementService
  dependsOn: [
    aiLoggerIdentity
  ]
  properties: {
    loggerType: 'applicationInsights'
    description: 'Application Insights logger with connection string'
    credentials: {
      connectionString: aiParent.properties.ConnectionString
      identityClientId: '{{ai-logger-identity}}'
    }
  }
}

// Service-level Application Insights diagnostic so all APIs log to App Insights by default.
resource serviceDiagnostic 'Microsoft.ApiManagement/service/diagnostics@2023-03-01-preview' = {
  parent: apiManagementService
  name: 'applicationinsights'
  properties: {
    alwaysLog: 'allErrors'
    httpCorrelationProtocol: 'W3C'
    verbosity: 'information'
    logClientIp: true
    loggerId: aiLoggerWithSystemAssignedIdentity.id
    metrics: true
    sampling: {
      samplingType: 'fixed'
      percentage: 100
    }
    frontend: {
      request: {
        headers: []
        body: {
          bytes: 0
        }
      }
      response: {
        headers: []
        body: {
          bytes: 0
        }
      }
    }
    backend: {
      request: {
        headers: []
        body: {
          bytes: 0
        }
      }
      response: {
        headers: []
        body: {
          bytes: 0
        }
      }
    }
  }
}

// Azure Monitor diagnostic settings on the APIM service.
// Sends generative AI gateway logs (GatewayLlmLogs) and standard gateway logs
// to a Log Analytics workspace so the ApiManagementGatewayLlmLog table is
// populated for token-usage / prompt-completion analytics.
// See https://learn.microsoft.com/azure/api-management/api-management-howto-llm-logs
// Direct management access, pinned off. Both are off on the live instances (the
// management REST API and the git configuration endpoint accept the tenant access
// keys, outside Entra ID and Azure RBAC, and their calls are not in the Activity
// log). Microsoft's advisory MZK9-GH0 (2026-11) listed tokens for the direct
// management API as possibly exposed. They are written after the other service
// writes and one after the other: on the Developer SKU, parallel child writes
// fail with ServiceLocked (see AGENTS.md).
resource tenantAccess 'Microsoft.ApiManagement/service/tenant@2024-05-01' = {
  parent: apiManagementService
  name: 'access'
  dependsOn: [
    serviceDiagnostic
  ]
  properties: {
    enabled: false
  }
}

resource tenantGitAccess 'Microsoft.ApiManagement/service/tenant@2024-05-01' = {
  parent: apiManagementService
  name: 'gitAccess'
  dependsOn: [
    tenantAccess
  ]
  properties: {
    enabled: false
  }
}

resource apimToLogAnalytics 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = if (!empty(logAnalyticsWorkspaceId)) {
  name: 'apim-genai-gateway-logs'
  scope: apiManagementService
  properties: {
    workspaceId: logAnalyticsWorkspaceId
    logAnalyticsDestinationType: 'Dedicated'
    logs: [
      {
        categoryGroup: 'allLogs'
        enabled: true
      }
      {
        categoryGroup: 'audit'
        enabled: false
      }
    ]
    metrics: [
      {
        category: 'AllMetrics'
        enabled: true
      }
    ]
  }
}

output apiManagementInternalIPAddress string = apiManagementService.properties.publicIPAddresses[0]
output apiManagementIdentityPrincipalId string = apiManagementService.identity.principalId
output apiManagementProxyHostName string = apiManagementService.properties.hostnameConfigurations[0].hostName
output apiManagementDeveloperPortalHostName string = !empty(apiManagementService.properties.developerPortalUrl ?? '') ? replace(apiManagementService.properties.developerPortalUrl!, 'https://', '') : ''
output aiLoggerId string = aiLoggerWithSystemAssignedIdentity.id
