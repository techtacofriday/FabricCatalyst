//******************************************************************
//INPUT PARAMETERS 
//******************************************************************
param location string = resourceGroup().location
param serverName string = 'template'
param sysAdminName string = 'dbserver-sql-admin'
@secure()
param sysAdminPsw string
param azADAdminLoginName string = 'SecurityGroup'
param azADAdminSid string = 'xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx'
param azADAdminType string = 'Group'
param azADOnlyAuthentication bool = true 

param resourceTags object = {}

//******************************************************************
//RESOURCES & MODULES 
//******************************************************************

resource sqlServerMixed 'Microsoft.Sql/servers@2021-11-01' = if (!azADOnlyAuthentication) {
  name: serverName
  location: location
  tags: resourceTags
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    administratorLogin: sysAdminName
    administratorLoginPassword: sysAdminPsw
    version: '12.0'
    minimalTlsVersion: '1.2'
    administrators: {
      administratorType: 'ActiveDirectory'
      login: azADAdminLoginName
      sid: azADAdminSid
      principalType: azADAdminType
      azureADOnlyAuthentication: azADOnlyAuthentication
    }
    publicNetworkAccess: 'Enabled'
  }
}

resource sqlServerMixed_AllowAllWindowsAzureIps 'Microsoft.Sql/servers/firewallRules@2024-05-01-preview' = if (!azADOnlyAuthentication) {
  parent: sqlServerMixed
  name: 'AllowAllWindowsAzureIps'
  properties: {
    startIpAddress: '0.0.0.0'
    endIpAddress: '0.0.0.0'
  }
}

resource sqlServerAADOnly 'Microsoft.Sql/servers@2021-11-01' = if (azADOnlyAuthentication) {
  name: serverName
  location: location
  tags: resourceTags
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    version: '12.0'
    minimalTlsVersion: '1.2'
    administrators: {
      administratorType: 'ActiveDirectory'
      login: azADAdminLoginName
      sid: azADAdminSid
      principalType: azADAdminType
      azureADOnlyAuthentication: azADOnlyAuthentication
    }
    publicNetworkAccess: 'Enabled'
  }
}

resource sqlServerAADOnly_AllowAllWindowsAzureIps 'Microsoft.Sql/servers/firewallRules@2024-05-01-preview' = if (azADOnlyAuthentication) {
  parent: sqlServerAADOnly
  name: 'AllowAllWindowsAzureIps'
  properties: {
    startIpAddress: '0.0.0.0'
    endIpAddress: '0.0.0.0'
  }
}

//******************************************************************
//OUTPUTS 
//******************************************************************
output sqlServerId string = azADOnlyAuthentication ? sqlServerAADOnly.id : sqlServerMixed.id
output sqlServerFQDN string = azADOnlyAuthentication ? sqlServerAADOnly.properties.fullyQualifiedDomainName : sqlServerMixed.properties.fullyQualifiedDomainName