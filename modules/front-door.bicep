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

@description('Host name clients use, such as aifapimv2-dev.nsls2.bnl.gov. Leave empty for the first deployment: the profile identity needs the Key Vault role before the certificate can be read.')
param customDomainHostName string = ''

@description('Resource ID of the Key Vault secret behind the certificate, in the subscription of this profile. The certificate must be RSA, with its intermediate certificates.')
param certificateSourceId string = ''

@description('Further host names this profile serves, each { hostName, certificateSourceId } (the secret in the same form as certificateSourceId). Each gets its own certificate secret and custom domain on the same route and WAF policy. Add them once the profile identity has the Key Vault role on each secret, which the parent template grants in the same deployment: if the first deployment fails reading a secret, run it again.')
param extraDomains array = []

@description('Whether the WAF inspects request bodies. A prompt with code or SQL can look like an attack to the managed rules, so turn it on only after a test with real prompts.')
param inspectRequestBody bool = false

@description('Version of the Microsoft default rule set (OWASP-based).')
param defaultRuleSetVersion string = '2.2'

@description('Version of the Microsoft bot manager rule set.')
param botManagerRuleSetVersion string = '1.1'

@description('Version of the HTTP DDoS rule set. Its rules log by default, and the rule set takes no action of its own.')
param ddosRuleSetVersion string = '1.0'

param tags object = {}

var useCustomDomain = !empty(customDomainHostName)

// Front Door waits this long for the first byte from the gateway, and for each pause in a body
// afterwards. Its maximum is 240 seconds.
resource profile 'Microsoft.Cdn/profiles@2024-02-01' = {
  name: profileName
  location: 'global'
  tags: tags
  sku: { name: 'Premium_AzureFrontDoor' }
  identity: { type: 'SystemAssigned' }
  properties: { originResponseTimeoutSeconds: 240 }
}

// Front Door reads the certificate from Key Vault with this identity (Key Vault Secrets User, granted
// in the parent template).
resource certificate 'Microsoft.Cdn/profiles/secrets@2024-02-01' = if (useCustomDomain) {
  parent: profile
  name: 'gateway-certificate'
  properties: {
    parameters: {
      type: 'CustomerCertificate'
      secretSource: { id: certificateSourceId }
      useLatestVersion: true
    }
  }
}

// With a certificate whose name matches the host name, Front Door approves the domain itself: no
// DNS validation record is needed. The CNAME to the endpoint is what moves traffic.
resource customDomain 'Microsoft.Cdn/profiles/customDomains@2024-02-01' = if (useCustomDomain) {
  parent: profile
  name: replace(customDomainHostName, '.', '-')
  properties: {
    hostName: customDomainHostName
    tlsSettings: {
      certificateType: 'CustomerCertificate'
      minimumTlsVersion: 'TLS12'
      secret: { id: certificate.id }
    }
  }
}

resource extraCertificates 'Microsoft.Cdn/profiles/secrets@2024-02-01' = [for d in extraDomains: {
  parent: profile
  name: 'cert-${replace(d.hostName, '.', '-')}'
  properties: {
    parameters: {
      type: 'CustomerCertificate'
      secretSource: { id: d.certificateSourceId }
      useLatestVersion: true
    }
  }
}]

resource extraCustomDomains 'Microsoft.Cdn/profiles/customDomains@2024-02-01' = [for (d, i) in extraDomains: {
  parent: profile
  name: replace(d.hostName, '.', '-')
  properties: {
    hostName: d.hostName
    tlsSettings: {
      certificateType: 'CustomerCertificate'
      minimumTlsVersion: 'TLS12'
      secret: { id: extraCertificates[i].id }
    }
  }
}]

var extraDomainRefs = [for (d, i) in extraDomains: { id: extraCustomDomains[i].id }]

resource endpoint 'Microsoft.Cdn/profiles/afdEndpoints@2024-02-01' = {
  parent: profile
  name: endpointName
  location: 'global'
  tags: tags
  properties: { enabledState: 'Enabled' }
}

// The allow-list custom rule runs first, so the managed rules only see listed clients.
// SocketAddr is the address of the connection that reached Front Door. RemoteAddr would follow
// X-Forwarded-For, which any caller can set.
resource waf 'Microsoft.Network/frontDoorWebApplicationFirewallPolicies@2024-02-01' = {
  name: wafPolicyName
  location: 'global'
  tags: tags
  sku: { name: 'Premium_AzureFrontDoor' }
  properties: {
    policySettings: {
      enabledState: 'Enabled'
      mode: 'Prevention'
      requestBodyCheck: inspectRequestBody ? 'Enabled' : 'Disabled'
    }
    managedRules: {
      managedRuleSets: [
        { ruleSetType: 'Microsoft_DefaultRuleSet', ruleSetVersion: defaultRuleSetVersion, ruleSetAction: 'Block' }
        { ruleSetType: 'Microsoft_BotManagerRuleSet', ruleSetVersion: botManagerRuleSetVersion }
        { ruleSetType: 'Microsoft_HTTPDDoSRuleSet', ruleSetVersion: ddosRuleSetVersion }
      ]
    }
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
    customDomains: concat(useCustomDomain ? [ { id: customDomain.id } ] : [], extraDomainRefs)
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
        {
          domains: concat([ { id: endpoint.id } ], useCustomDomain ? [ { id: customDomain.id } ] : [], extraDomainRefs)
          patternsToMatch: [ '/*' ]
        }
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
output identityPrincipalId string = profile.identity.principalId
