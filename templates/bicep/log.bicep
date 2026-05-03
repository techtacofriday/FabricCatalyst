//******************************************************************
//INPUT PARAMETERS 
//******************************************************************
param logAnalyticsWorkspaceName string = ''
param location string = ''
param diagnosticLogRetentionPeriod int = 0
//RESOURCE TAGS
param resourceTags object = {}

//******************************************************************
//RESOURCES & MODULES 
//******************************************************************
resource logAnalyticsWorkspace 'Microsoft.OperationalInsights/workspaces@2020-03-01-preview' = {
  name: logAnalyticsWorkspaceName
  location: location
  tags: resourceTags
  properties: any({
    retentionInDays: diagnosticLogRetentionPeriod
    features: {
      searchVersion: 1
    }
    sku: {
      name: 'PerGB2018'
    }
    publicNetworkAccessForIngestion: 'Enabled'
    publicNetworkAccessForQuery: 'Enabled'
  })
}

//******************************************************************
//OUTPUTS 
//******************************************************************
output logAnalyticsWorkspaceId string = logAnalyticsWorkspace.id
