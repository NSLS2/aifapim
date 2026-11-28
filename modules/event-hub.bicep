param eventHubNamespaceName string
param eventHubName string
param skuName string = 'Standard'
param skuCapacity int = 1
param location string = resourceGroup().location
param tags object = {}

@description('Subnet resource ID for the namespace private endpoint. Private endpoints need the Standard or Premium SKU.')
param subnetId string

@description('Resource ID of the privatelink.servicebus.windows.net private DNS zone to register the private endpoint in.')
param privateDnsZoneId string

@description('Region of the private endpoint. Must be the region of the subnet virtual network.')
param privateEndpointLocation string = location

@description('Addresses and ranges allowed to reach the public endpoint, for a reader outside the VNet. Empty (and no trusted services) keeps public network access Disabled. Traffic through the private endpoint is not affected.')
param allowedIps array = []

@description('Let trusted Azure services past the firewall. API Management needs it: its management plane tests the connection from outside the VNet when it creates a logger. The gateway itself sends through the private endpoint.')
param allowTrustedServices bool = false

@description('Consumer group to create for a reader. Empty creates none ($Default always exists).')
param consumerGroupName string = ''

var useRules = !empty(allowedIps) || allowTrustedServices

resource eventHubNamespace 'Microsoft.EventHub/namespaces@2024-01-01' = {
  name: eventHubNamespaceName
  location: location
  tags: tags
  sku: {
    name: skuName
    capacity: skuCapacity
  }
  properties: {
    disableLocalAuth: true
    minimumTlsVersion: '1.2'
    publicNetworkAccess: useRules ? 'Enabled' : 'Disabled'
  }
}

resource eventHub 'Microsoft.EventHub/namespaces/eventhubs@2024-01-01' = {
  parent: eventHubNamespace
  name: eventHubName
}

resource consumerGroup 'Microsoft.EventHub/namespaces/eventhubs/consumergroups@2024-01-01' = if (!empty(consumerGroupName)) {
  parent: eventHub
  name: consumerGroupName
}

resource networkRules 'Microsoft.EventHub/namespaces/networkRuleSets@2024-01-01' = if (useRules) {
  parent: eventHubNamespace
  name: 'default'
  properties: {
    publicNetworkAccess: 'Enabled'
    defaultAction: 'Deny'
    trustedServiceAccessEnabled: allowTrustedServices
    ipRules: [for ip in allowedIps: { ipMask: ip, action: 'Allow' }]
  }
}

// Private endpoint into the VNet; without it the namespace has no data-plane
// path once public network access is disabled.
resource privateEndpoint 'Microsoft.Network/privateEndpoints@2023-11-01' = {
  name: 'pe-${eventHubNamespace.name}'
  location: privateEndpointLocation
  tags: tags
  properties: {
    subnet: {
      id: subnetId
    }
    privateLinkServiceConnections: [
      {
        name: 'plsc-${eventHubNamespace.name}'
        properties: {
          privateLinkServiceId: eventHubNamespace.id
          groupIds: [
            'namespace'
          ]
        }
      }
    ]
  }
}

resource privateDnsZoneGroup 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2023-11-01' = {
  parent: privateEndpoint
  name: 'default'
  properties: {
    privateDnsZoneConfigs: [
      {
        name: 'config-0'
        properties: {
          privateDnsZoneId: privateDnsZoneId
        }
      }
    ]
  }
}

output namespaceId string = eventHubNamespace.id
output eventHubId string = eventHub.id
