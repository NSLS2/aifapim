// A private endpoint into the virtual network for an existing AI Foundry account, which can
// be in another resource group, and its registration in the private DNS zones.

@description('Region of the private endpoint: the region of the virtual network, not of the account.')
param location string

@description('Name of the existing AI Foundry (AIServices) account.')
param accountName string

@description('Resource group of the account.')
param accountResourceGroup string

@description('Resource ID of the subnet for the private endpoint.')
param subnetId string

@description('Private DNS zones to register the endpoint in. AI Services accounts need privatelink.openai.azure.com, privatelink.cognitiveservices.azure.com and privatelink.services.ai.azure.com.')
param privateDnsZoneIds array

param tags object = {}

resource account 'Microsoft.CognitiveServices/accounts@2024-10-01' existing = {
  name: accountName
  scope: resourceGroup(accountResourceGroup)
}

resource privateEndpoint 'Microsoft.Network/privateEndpoints@2023-11-01' = {
  name: 'pe-${accountName}'
  location: location
  tags: tags
  properties: {
    subnet: {
      id: subnetId
    }
    privateLinkServiceConnections: [
      {
        name: 'plsc-${accountName}'
        properties: {
          privateLinkServiceId: account.id
          groupIds: [
            'account'
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
      for (zoneId, i) in privateDnsZoneIds: {
        name: 'config-${i}'
        properties: {
          privateDnsZoneId: zoneId
        }
      }
    ]
  }
}
