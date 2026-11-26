// API Management Standard v2 for the aifapimv2 stacks. Like api-management-private.bicep, but
// for the v2 tier: outbound traffic goes through a delegated subnet, and the settings the v2
// tiers do not have are left out (cipher settings, the service-wide CA certificates, the
// direct management API and Git configuration, the legacy portal).

@description('The location of the API Management instance. It must be the region of the virtual network.')
param location string

@description('The name of the API Management service instance. This must be globally unique.')
param serviceName string

@description('The name of the API publisher.')
param publisherName string

@description('The email address of the API publisher.')
param publisherEmail string

@description('Name of the Application Insights component the logger writes to.')
param aiName string

@description('The v2 SKU.')
@allowed([
  'StandardV2'
  'PremiumV2'
])
param skuName string = 'StandardV2'

@description('The number of units.')
param skuCount int = 1

@description('Resource ID of the subnet for outbound virtual network integration (delegated to Microsoft.Web/serverFarms).')
param subnetResourceId string

@description('Custom gateway host name. Leave empty to skip. It needs the Key Vault role of the system-assigned identity, which exists only after the instance does: deploy first without it.')
param gatewayHostName string = ''

@description('Name of the Key Vault with the gateway certificate.')
param keyVaultName string = ''

@description('Key Vault secret name of the gateway certificate.')
param gatewayKeyVaultSecretName string = ''

@description('Resource ID of the Log Analytics workspace for the diagnostic logs (including the generative AI gateway logs). Leave empty to skip.')
param logAnalyticsWorkspaceId string = ''

param tags object = {}

var enableCustomDomain = !empty(gatewayHostName) && !empty(gatewayKeyVaultSecretName)

// The default host name stays, as in api-management-private.bicep: it is the one to test on
// before DNS exists.
var hostnameConfigurations = concat(
  [
    {
      type: 'Proxy'
      hostName: '${serviceName}.azure-api.net'
      negotiateClientCertificate: false
      defaultSslBinding: !enableCustomDomain
    }
  ],
  enableCustomDomain
    ? [
        {
          type: 'Proxy'
          hostName: gatewayHostName
          negotiateClientCertificate: false
          defaultSslBinding: true
          keyVaultId: 'https://${keyVaultName}${environment().suffixes.keyvaultDns}/secrets/${gatewayKeyVaultSecretName}'
        }
      ]
    : []
)

resource aiParent 'Microsoft.Insights/components@2020-02-02-preview' existing = {
  name: aiName
}

resource apiManagementService 'Microsoft.ApiManagement/service@2024-05-01' = {
  name: serviceName
  location: location
  tags: tags
  sku: {
    name: skuName
    capacity: skuCount
  }
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    publisherName: publisherName
    publisherEmail: publisherEmail
    virtualNetworkType: 'External'
    virtualNetworkConfiguration: {
      subnetResourceId: subnetResourceId
    }
    hostnameConfigurations: hostnameConfigurations
    developerPortalStatus: 'Disabled'
    apiVersionConstraint: {
      minApiVersion: '2021-08-01'
    }
  }
}

// APIM keeps a logger's identityClientId in a secret named value and writes a new one on
// every deployment that writes the logger, so the logger gets one plain named value of our
// own (see api-management-private.bicep).
resource aiLoggerIdentity 'Microsoft.ApiManagement/service/namedValues@2024-05-01' = {
  parent: apiManagementService
  name: 'ai-logger-identity'
  properties: {
    displayName: 'ai-logger-identity'
    value: 'systemAssigned'
    secret: false
  }
}

resource aiLogger 'Microsoft.ApiManagement/service/loggers@2024-05-01' = {
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
resource serviceDiagnostic 'Microsoft.ApiManagement/service/diagnostics@2024-05-01' = {
  parent: apiManagementService
  name: 'applicationinsights'
  properties: {
    alwaysLog: 'allErrors'
    httpCorrelationProtocol: 'W3C'
    verbosity: 'information'
    logClientIp: true
    loggerId: aiLogger.id
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

// Sends the gateway logs, including the generative AI gateway logs (GatewayLlmLogs), to Log
// Analytics so the ApiManagementGatewayLlmLog table is populated.
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

output apiManagementIdentityPrincipalId string = apiManagementService.identity.principalId
output apiManagementDefaultHostName string = '${serviceName}.azure-api.net'
output aiLoggerId string = aiLogger.id
