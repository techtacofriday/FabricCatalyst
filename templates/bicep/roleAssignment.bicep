
//******************************************************************
// ROLE ASSIGNMENT MODULE
// Scope-agnostic: the caller controls the scope by setting the
// module's scope property at the call site (e.g. scope: existingKv).
// The assignment name is a stable GUID derived from principal + role.
//******************************************************************
param roleDefinitionId string
param principalId string

@allowed(['User', 'ServicePrincipal', 'Group'])
param principalType string = 'ServicePrincipal'

var assignmentName = guid(principalId, roleDefinitionId)

resource roleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: assignmentName
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roleDefinitionId)
    principalId: principalId
    principalType: principalType
  }
}
