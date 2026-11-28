@description('Name of the Log Analytics workspace, in this resource group.')
param workspaceName string

@description('Object id of the principal that reads the tables (the Grafana app).')
param principalId string

@description('Tables the principal may read: what the Grafana dashboard queries. The prompts and answers table, ApiManagementGatewayLlmLog, is not in it.')
param tableNames array = [
  'ApiManagementGatewayLogs'
  'AppMetrics'
  'AzureDiagnostics'
  'AzureMetrics'
  'LlmModelCost_CL'
]

resource workspace 'Microsoft.OperationalInsights/workspaces@2023-09-01' existing = {
  name: workspaceName
}

// Granular RBAC: Log Analytics Data Reader limited to the listed tables by a condition. It
// only limits when the principal has no wider read role over the workspace (Log Analytics
// Reader, Reader, Monitoring Reader on it or above it): roles add up.
resource tableReader 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(workspace.id, principalId, 'table-reader')
  scope: workspace
  properties: {
    principalId: principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '3b03c2da-16b3-4a49-8834-0f8130efdd3b') // Log Analytics Data Reader
    conditionVersion: '2.0'
    condition: '((!(ActionMatches{\'Microsoft.OperationalInsights/workspaces/tables/data/read\'})) OR (@Resource[Microsoft.OperationalInsights/workspaces/tables:name] ForAllOfAnyValues:StringEquals {${join(map(tableNames, t => '\'${t}\''), ', ')}}))'
  }
}
