// Sends one event per request to an Event Hub: a logger on the gateway's system-assigned identity
// (the identity needs Azure Event Hubs Data Sender on the namespace, granted in the parent) and the
// service-level policy that writes the event after every request and every error. It replaces the
// default service policy, which only forwards the request. See apim_policies/SecurityEvent_Fragment.xml.

param apimName string
param eventHubNamespaceName string
param eventHubName string

@description('Service-level policy document with the security event marker in outbound and on-error.')
param policyXml string

resource apim 'Microsoft.ApiManagement/service@2024-05-01' existing = {
  name: apimName
}

// The named value of the Application Insights logger holds 'systemAssigned' (api-management-v2.bicep).
resource logger 'Microsoft.ApiManagement/service/loggers@2024-05-01' = {
  parent: apim
  name: 'security-events'
  properties: {
    loggerType: 'azureEventHub'
    description: 'Security events to the Event Hub'
    credentials: {
      name: eventHubName
      endpointAddress: '${eventHubNamespaceName}.servicebus.windows.net'
      identityClientId: '{{ai-logger-identity}}'
    }
  }
}

resource policy 'Microsoft.ApiManagement/service/policies@2024-05-01' = {
  parent: apim
  name: 'policy'
  dependsOn: [ logger ]
  properties: {
    format: 'rawxml'
    value: policyXml
  }
}
