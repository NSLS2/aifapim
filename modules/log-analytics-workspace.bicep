param location string
param logAnalyticsName string

// A year, up from 90 days (Azure advisory MZK9-GH0, 2026-11: the log review needs history
// from before the issue was found). Raising it keeps older rows; it does not recover any.
@minValue(30)
@maxValue(730)
param retentionInDays int = 365

// The gateway's built-in LLM log (prompts and answers) is kept 12 years, the most Log Analytics
// keeps: searchable for retentionInDays, then in long-term storage. Set on the table, because
// the workspace setting alone would delete it after retentionInDays.
@minValue(30)
@maxValue(4383)
param llmLogTotalRetentionInDays int = 4383
param tags object = {}

resource logAnalyticcsWorkspace 'Microsoft.OperationalInsights/workspaces@2020-08-01' = {
  name: logAnalyticsName
  location: location
  tags: tags
  properties: {
    sku: {
      name: 'PerGB2018'
    }
    retentionInDays: retentionInDays
  }
}

resource llmLogTable 'Microsoft.OperationalInsights/workspaces/tables@2022-10-01' = {
  parent: logAnalyticcsWorkspace
  name: 'ApiManagementGatewayLlmLog'
  properties: {
    retentionInDays: retentionInDays
    totalRetentionInDays: llmLogTotalRetentionInDays
  }
}

output id string = logAnalyticcsWorkspace.id
output name string = logAnalyticcsWorkspace.name
