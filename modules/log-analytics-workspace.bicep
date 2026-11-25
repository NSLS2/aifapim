param location string
param logAnalyticsName string

// A year, up from 90 days (Azure advisory MZK9-GH0, 2026-11: the log review needs history
// from before the issue was found). Raising it keeps older rows; it does not recover any.
@minValue(30)
@maxValue(730)
param retentionInDays int = 365
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

output id string = logAnalyticcsWorkspace.id
output name string = logAnalyticcsWorkspace.name
