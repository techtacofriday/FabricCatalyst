//******************************************************************
//INPUT PARAMETERS 
//******************************************************************
//DEPLOYMENT ENVIRONMENT 
param environment string = 'd'
param azTenantId string = '8650e436-efa2-46c3-8288-a56355c8ebb8'
param azSubscriptionId string = '0efa21d6-26d2-4cdd-b5fe-6082d08c3032'
param azResourceGroupName string = 'fabriccatalyst-d-rg'
param azResourceGroupLocation string = 'norwayeast'
//KEY VAULT 
param azKeyVaultName string = 'fabcat-shared-d-kv-ne'
//SQL SERVER 
param azSqlServerName string = 'fabcat-shared-d-sql-ne'
param azSqlServerSysAdminName string = 'dbserver-sql-admin'
@secure()
param azSqlServerSysAdminPsw string
param azSqlServerAADAdminLoginName string = 'admin.hlopez@acnazure034hotmail.onmicrosoft.com'
param azSqlServerAADAdminSid string = 'cd6b2f79-dfce-4380-a40b-fbb055f882ed'
param azSqlServerAADAdminType string = 'User'
param azADOnlyAuthentication bool = false  
//SQL DATABASE 
param azSqlDBName string = 'MyAzureSQLDB'
//LOG ANALYTICS WORKSPACE & APP INSIGHTS  
param logAnalyticsWorkspaceName string = 'fabcat-shared-d-log-ne'
param diagnosticLogRetentionPeriod int = 0

//******************************************************************
//VARIABLES
//******************************************************************
var parentResourceTags = {
    'Avanade Owner': 'hector.lopez@accenture.com'
    environment: environment
}

//******************************************************************
//RESOURCES & MODULES 
//******************************************************************
targetScope = 'resourceGroup' //MANDATORY IF YOU WANT TO CREATE A RESOURCE GROUP

//CREATE AN AZURE KEY VAULT FROM THE GENERIC TEMPLATE 
module keyVault '../../../templates/bicep/kv.bicep' = {
  name: azKeyVaultName
  scope: resourceGroup(azSubscriptionId, azResourceGroupName)
  params: {
    keyVaultName: azKeyVaultName
    tenantId: azTenantId
    resourceTags: parentResourceTags
    location: azResourceGroupLocation
  }
}

module sqlServer '../../../templates/bicep/sql.bicep' = {
  name: azSqlServerName
  scope: resourceGroup(azSubscriptionId, azResourceGroupName)
  params: {
    location: azResourceGroupLocation
    serverName: azSqlServerName
    sysAdminName: azSqlServerSysAdminName
    sysAdminPsw: azSqlServerSysAdminPsw
    azADAdminLoginName: azSqlServerAADAdminLoginName
    azADAdminSid: azSqlServerAADAdminSid
    azADAdminType: azSqlServerAADAdminType
    azADOnlyAuthentication: azADOnlyAuthentication
    resourceTags: parentResourceTags
  }
}

module sqlDatabase '../../../templates/bicep/sqldb.bicep' = {
  name: azSqlDBName
  scope: resourceGroup(azSubscriptionId, azResourceGroupName)
  params: {
    location: azResourceGroupLocation
    serverName: azSqlServerName
    sqlDBName: azSqlDBName
  }
  dependsOn: [sqlServer]
}

//CREATE A LOG ANALYSTICS FOR ABBI 
module logAnalyticsWorkspace '../../../templates/bicep/log.bicep' = {
  name: logAnalyticsWorkspaceName
  scope: resourceGroup(azSubscriptionId, azResourceGroupName)
  params: {
    logAnalyticsWorkspaceName: logAnalyticsWorkspaceName
    diagnosticLogRetentionPeriod: diagnosticLogRetentionPeriod
    location: azResourceGroupLocation
    resourceTags: parentResourceTags
  }
}

//******************************************************************
//OUTPUTS 
//******************************************************************