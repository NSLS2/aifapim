// Front Door Premium in front of the API Management gateway, over Private Link. It is the only
// public entry once the gateway has publicNetworkAccess Disabled, and it needs no public IP
// resource of ours. The Private Link connection it requests on the gateway is approved by hand:
//   az network private-endpoint-connection approve --id <connection id>
// See APIM_V2_MIGRATION.md.

@description('Name of the Front Door profile.')
param profileName string

@description('Name of the endpoint, which becomes <name>-<hash>.<zone>.azurefd.net.')
param endpointName string

@description('Name of the WAF policy (letters and digits only).')
param wafPolicyName string

@description('Resource ID of the API Management instance.')
param apimId string

@description('Default host name of the API Management gateway.')
param apimHostName string

@description('Region of the API Management instance, where Front Door creates the private endpoint.')
param apimLocation string

@description('Addresses and ranges allowed to call. Everything else is blocked at the edge.')
param allowedClientIps array

@description('Resource ID of the Log Analytics workspace for the access, health probe and WAF logs.')
param logAnalyticsWorkspaceId string

param tags object = {}

// Front Door waits this long for the first byte from the gateway, and for each pause in a body
// afterwards. Its maximum is 240 seconds.
resource profile 'Microsoft.Cdn/profiles@2024-02-01' = {
  name: profileName
  location: 'global'
  tags: tags
  sku: { name: 'Premium_AzureFrontDoor' }
  properties: { originResponseTimeoutSeconds: 240 }
}

resource endpoint 'Microsoft.Cdn/profiles/afdEndpoints@2024-02-01' = {
  parent: profile
  name: endpointName
  location: 'global'
  tags: tags
  properties: { enabledState: 'Enabled' }
}

// SocketAddr is the address of the connection that reached Front Door. RemoteAddr would follow
// X-Forwarded-For, which any caller can set.
resource waf 'Microsoft.Network/frontDoorWebApplicationFirewallPolicies@2024-02-01' = {
  name: wafPolicyName
  location: 'global'
  tags: tags
  sku: { name: 'Premium_AzureFrontDoor' }
  properties: {
    policySettings: { enabledState: 'Enabled', mode: 'Prevention' }
    customRules: {
      rules: [
        {
          name: 'BlockUnlistedClients'
          priority: 100
          ruleType: 'MatchRule'
          action: 'Block'
          matchConditions: [
            {
              matchVariable: 'SocketAddr'
              operator: 'IPMatch'
              negateCondition: true
              matchValue: allowedClientIps
            }
          ]
        }
      ]
    }
  }
}

resource originGroup 'Microsoft.Cdn/profiles/originGroups@2024-02-01' = {
  parent: profile
  name: 'apim'
  properties: {
    sessionAffinityState: 'Disabled'
    loadBalancingSettings: { sampleSize: 4, successfulSamplesRequired: 3, additionalLatencyInMilliseconds: 50 }
    healthProbeSettings: {
      probePath: '/status-0123456789abcdef'
      probeRequestType: 'GET'
      probeProtocol: 'Https'
      probeIntervalInSeconds: 100
    }
  }
}

resource origin 'Microsoft.Cdn/profiles/originGroups/origins@2024-02-01' = {
  parent: originGroup
  name: 'apim-gateway'
  properties: {
    hostName: apimHostName
    originHostHeader: apimHostName
    httpsPort: 443
    priority: 1
    weight: 1000
    enabledState: 'Enabled'
    enforceCertificateNameCheck: true
    sharedPrivateLinkResource: {
      privateLink: { id: apimId }
      privateLinkLocation: apimLocation
      groupId: 'Gateway'
      requestMessage: 'Front Door ${profileName}'
    }
  }
}

resource route 'Microsoft.Cdn/profiles/afdEndpoints/routes@2024-02-01' = {
  parent: endpoint
  name: 'default'
  dependsOn: [ origin ]
  properties: {
    originGroup: { id: originGroup.id }
    supportedProtocols: [ 'Https' ]
    patternsToMatch: [ '/*' ]
    forwardingProtocol: 'HttpsOnly'
    httpsRedirect: 'Enabled'
    linkToDefaultDomain: 'Enabled'
  }
}

resource security 'Microsoft.Cdn/profiles/securityPolicies@2024-02-01' = {
  parent: profile
  name: 'waf'
  properties: {
    parameters: {
      type: 'WebApplicationFirewall'
      wafPolicy: { id: waf.id }
      associations: [
        { domains: [ { id: endpoint.id } ], patternsToMatch: [ '/*' ] }
      ]
    }
  }
}

resource logs 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: 'front-door-logs'
  scope: profile
  properties: {
    workspaceId: logAnalyticsWorkspaceId
    logs: [
      { category: 'FrontDoorAccessLog', enabled: true }
      { category: 'FrontDoorHealthProbeLog', enabled: true }
      { category: 'FrontDoorWebApplicationFirewallLog', enabled: true }
    ]
  }
}

output endpointHostName string = endpoint.properties.hostName
