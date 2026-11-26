// Stage 1 of the Premium v2 gateway stacks (aifapimv2 and aifapimv2-dev): the virtual
// network. The gateway itself (aifapimv2.bicep) is deployed later into this network.
//
// Why a separate template: an API Management Premium v2 instance can only be placed in
// a virtual network when it is created, and the Key Vault firewall can only name subnets
// that already exist, so the network is deployed first and on its own. Plan:
// APIM_V2_MIGRATION.md.
//
// Subnets:
//   apim  API Management Premium v2 (injection). Delegated to the service, dedicated to
//         one instance. Apart from health probes and its own units, the only inbound
//         traffic allowed is HTTPS from the agw subnet.
//   agw   Application Gateway, the only public entry. The Microsoft.KeyVault service
//         endpoint lets it read its certificate from the firewalled Key Vault (add this
//         subnet to the vault, see the bicep repository, azure/infra-certificates).
//   pe    Private endpoints (Foundry accounts, Event Hub, request log storage).
//
// The outbound rules of the apim subnet allow what is documented or known to be needed
// and do not yet deny Internet traffic: add that rule once the flows of a running dev
// gateway are known (plan, phase 3).

@description('Azure region. It must be the region of the API Management instance.')
param location string = resourceGroup().location

@description('Tags to apply to all resources.')
param tags object = {
  'managed-by': 'bicep'
  project: 'aifapim'
  repository: 'NSLS2/aifapim'
}

@description('Name of the virtual network.')
param vnetName string

@description('Address space of the virtual network.')
param vnetAddressPrefix string

@description('Subnet for API Management Premium v2. Dedicated to one instance; /27 is the minimum and /24 is recommended.')
param apimSubnetPrefix string

@description('Subnet for the Application Gateway. Dedicated to it; /24 is recommended.')
param gatewaySubnetPrefix string

@description('Subnet for private endpoints.')
param privateEndpointSubnetPrefix string

@description('Sources allowed to reach the Application Gateway on port 443. Empty allows the whole Internet.')
param gatewayInboundSources array = []

var nsgPrefix = 'nsg-${vnetName}'

resource vnet 'Microsoft.Network/virtualNetworks@2023-11-01' = {
  name: vnetName
  location: location
  tags: tags
  properties: {
    addressSpace: {
      addressPrefixes: [
        vnetAddressPrefix
      ]
    }
  }
}

resource apimNsg 'Microsoft.Network/networkSecurityGroups@2023-11-01' = {
  name: '${nsgPrefix}-apim'
  location: location
  tags: tags
  properties: {
    securityRules: [
      {
        name: 'Allow_Inbound_HTTPS_From_Application_Gateway'
        properties: {
          protocol: 'Tcp'
          sourcePortRange: '*'
          destinationPortRange: '443'
          sourceAddressPrefix: gatewaySubnetPrefix
          destinationAddressPrefix: apimSubnetPrefix
          access: 'Allow'
          priority: 100
          direction: 'Inbound'
        }
      }
      {
        // The units of one instance talk to each other (cache, rate-limit counters).
        name: 'Allow_Inbound_Within_Subnet'
        properties: {
          protocol: '*'
          sourcePortRange: '*'
          destinationPortRange: '*'
          sourceAddressPrefix: apimSubnetPrefix
          destinationAddressPrefix: apimSubnetPrefix
          access: 'Allow'
          priority: 200
          direction: 'Inbound'
        }
      }
      {
        // The VirtualNetwork tag includes 168.63.129.16, where the health probes come
        // from, so the deny below would override the default probe rule.
        name: 'Allow_Inbound_Azure_Load_Balancer'
        properties: {
          protocol: '*'
          sourcePortRange: '*'
          destinationPortRange: '*'
          sourceAddressPrefix: 'AzureLoadBalancer'
          destinationAddressPrefix: '*'
          access: 'Allow'
          priority: 210
          direction: 'Inbound'
        }
      }
      {
        name: 'Deny_Inbound_VirtualNetwork'
        properties: {
          description: 'Nothing else in the virtual network may call the gateway.'
          protocol: '*'
          sourcePortRange: '*'
          destinationPortRange: '*'
          sourceAddressPrefix: 'VirtualNetwork'
          destinationAddressPrefix: '*'
          access: 'Deny'
          priority: 4000
          direction: 'Inbound'
        }
      }
      {
        name: 'Allow_Outbound_Azure_KeyVault'
        properties: {
          description: 'Documented dependency of API Management Premium v2 injection.'
          protocol: 'Tcp'
          sourcePortRange: '*'
          destinationPortRange: '443'
          sourceAddressPrefix: 'VirtualNetwork'
          destinationAddressPrefix: 'AzureKeyVault'
          access: 'Allow'
          priority: 100
          direction: 'Outbound'
        }
      }
      {
        name: 'Allow_Outbound_Azure_Active_Directory'
        properties: {
          description: 'Entra ID metadata and signing keys for validate-azure-ad-token.'
          protocol: 'Tcp'
          sourcePortRange: '*'
          destinationPortRange: '443'
          sourceAddressPrefix: 'VirtualNetwork'
          destinationAddressPrefix: 'AzureActiveDirectory'
          access: 'Allow'
          priority: 110
          direction: 'Outbound'
        }
      }
      {
        name: 'Allow_Outbound_Within_Subnet'
        properties: {
          protocol: '*'
          sourcePortRange: '*'
          destinationPortRange: '*'
          sourceAddressPrefix: apimSubnetPrefix
          destinationAddressPrefix: apimSubnetPrefix
          access: 'Allow'
          priority: 200
          direction: 'Outbound'
        }
      }
      {
        // Foundry accounts, request log storage and the Azure Monitor private link are
        // reached through private endpoints, whose addresses fall under VirtualNetwork.
        name: 'Allow_Outbound_HTTPS_To_Private_Endpoints'
        properties: {
          protocol: 'Tcp'
          sourcePortRange: '*'
          destinationPortRange: '443'
          sourceAddressPrefix: 'VirtualNetwork'
          destinationAddressPrefix: privateEndpointSubnetPrefix
          access: 'Allow'
          priority: 300
          direction: 'Outbound'
        }
      }
      {
        name: 'Allow_Outbound_AMQP_To_Private_Endpoints'
        properties: {
          description: 'Event Hub logger (TCP 5671-5672).'
          protocol: 'Tcp'
          sourcePortRange: '*'
          destinationPortRange: '5671-5672'
          sourceAddressPrefix: 'VirtualNetwork'
          destinationAddressPrefix: privateEndpointSubnetPrefix
          access: 'Allow'
          priority: 310
          direction: 'Outbound'
        }
      }
      {
        name: 'Deny_Lateral_Outbound_VirtualNetwork'
        properties: {
          description: 'Deny outbound lateral management connections from non-management hosts (Azure.NSG.LateralTraversal).'
          protocol: '*'
          sourcePortRange: '*'
          destinationPortRange: '*'
          sourceAddressPrefix: 'VirtualNetwork'
          destinationAddressPrefix: 'VirtualNetwork'
          access: 'Deny'
          priority: 4096
          direction: 'Outbound'
        }
      }
    ]
  }
}

// No outbound rules: for a standard (not network isolated) Application Gateway Microsoft
// requires the default outbound rules and says custom outbound deny rules must not be
// created.
resource gatewayNsg 'Microsoft.Network/networkSecurityGroups@2023-11-01' = {
  name: '${nsgPrefix}-agw'
  location: location
  tags: tags
  properties: {
    securityRules: [
      {
        name: 'Allow_Inbound_HTTPS_From_Allowed_Sources'
        properties: {
          protocol: 'Tcp'
          sourcePortRange: '*'
          destinationPortRange: '443'
          sourceAddressPrefix: empty(gatewayInboundSources) ? 'Internet' : null
          sourceAddressPrefixes: empty(gatewayInboundSources) ? null : gatewayInboundSources
          destinationAddressPrefix: gatewaySubnetPrefix
          access: 'Allow'
          priority: 100
          direction: 'Inbound'
        }
      }
      {
        name: 'Allow_Inbound_Application_Gateway_Management'
        properties: {
          description: 'Required by Application Gateway v2.'
          protocol: 'Tcp'
          sourcePortRange: '*'
          destinationPortRange: '65200-65535'
          sourceAddressPrefix: 'GatewayManager'
          destinationAddressPrefix: '*'
          access: 'Allow'
          priority: 110
          direction: 'Inbound'
        }
      }
      {
        // Same reason as on the apim subnet; Microsoft says this rule must not be
        // overridden by a deny.
        name: 'Allow_Inbound_Azure_Load_Balancer'
        properties: {
          protocol: '*'
          sourcePortRange: '*'
          destinationPortRange: '*'
          sourceAddressPrefix: 'AzureLoadBalancer'
          destinationAddressPrefix: '*'
          access: 'Allow'
          priority: 120
          direction: 'Inbound'
        }
      }
      {
        // Platform health monitoring (TCP 65502 and 54321, UDP 12345) must not be blocked.
        name: 'Allow_Inbound_Within_Subnet'
        properties: {
          protocol: '*'
          sourcePortRange: '*'
          destinationPortRange: '*'
          sourceAddressPrefix: gatewaySubnetPrefix
          destinationAddressPrefix: gatewaySubnetPrefix
          access: 'Allow'
          priority: 130
          direction: 'Inbound'
        }
      }
      {
        name: 'Deny_Inbound_VirtualNetwork'
        properties: {
          description: 'Nothing else in the virtual network may call the Application Gateway.'
          protocol: '*'
          sourcePortRange: '*'
          destinationPortRange: '*'
          sourceAddressPrefix: 'VirtualNetwork'
          destinationAddressPrefix: '*'
          access: 'Deny'
          priority: 4000
          direction: 'Inbound'
        }
      }
    ]
  }
}

resource privateEndpointNsg 'Microsoft.Network/networkSecurityGroups@2023-11-01' = {
  name: '${nsgPrefix}-pe'
  location: location
  tags: tags
  properties: {
    securityRules: [
      {
        name: 'Deny_Lateral_Outbound_VirtualNetwork'
        properties: {
          description: 'Deny outbound lateral management connections from non-management hosts (Azure.NSG.LateralTraversal).'
          protocol: '*'
          sourcePortRange: '*'
          destinationPortRange: '*'
          sourceAddressPrefix: 'VirtualNetwork'
          destinationAddressPrefix: 'VirtualNetwork'
          access: 'Deny'
          priority: 4096
          direction: 'Outbound'
        }
      }
    ]
  }
}

var subnets = [
  {
    name: 'apim'
    prefix: apimSubnetPrefix
    nsgId: apimNsg.id
    delegation: 'Microsoft.ApiManagement/service'
    serviceEndpoints: []
    defaultOutboundAccess: true
  }
  {
    name: 'agw'
    prefix: gatewaySubnetPrefix
    nsgId: gatewayNsg.id
    delegation: ''
    serviceEndpoints: [
      'Microsoft.KeyVault'
    ]
    defaultOutboundAccess: true
  }
  {
    name: 'pe'
    prefix: privateEndpointSubnetPrefix
    nsgId: privateEndpointNsg.id
    delegation: ''
    serviceEndpoints: []
    defaultOutboundAccess: false
  }
]

// Declared as child resources, one after the other, so that a redeployment keeps subnets
// added later (the request log function subnet) and avoids concurrent updates of the
// virtual network.
@batchSize(1)
resource subnetResources 'Microsoft.Network/virtualNetworks/subnets@2023-11-01' = [
  for subnet in subnets: {
    parent: vnet
    name: subnet.name
    properties: {
      addressPrefix: subnet.prefix
      networkSecurityGroup: {
        id: subnet.nsgId
      }
      delegations: empty(subnet.delegation)
        ? []
        : [
            {
              name: 'delegation'
              properties: {
                serviceName: subnet.delegation
              }
            }
          ]
      serviceEndpoints: [
        for endpoint in subnet.serviceEndpoints: {
          service: endpoint
        }
      ]
      defaultOutboundAccess: subnet.defaultOutboundAccess
    }
  }
]

output vnetName string = vnet.name
output vnetId string = vnet.id
output subnetIds object = toObject(
  subnets,
  subnet => subnet.name,
  subnet => resourceId('Microsoft.Network/virtualNetworks/subnets', vnet.name, subnet.name)
)
