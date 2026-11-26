@description('Name of the existing Key Vault to grant access to.')
param keyVaultName string

@description('Name of the secret in the vault to scope the role to.')
param secretName string

@description('Role assignment name (GUID).')
param roleName string

@description('Principal ID to grant access to.')
param principalId string

@description('Principal type.')
param principalType string = 'ServicePrincipal'

@description('Role definition ID to assign.')
param roleDefinitionId string

resource keyVault 'Microsoft.KeyVault/vaults@2023-07-01' existing = {
  name: keyVaultName
}

resource secret 'Microsoft.KeyVault/vaults/secrets@2023-07-01' existing = {
  parent: keyVault
  name: secretName
}

resource roleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: roleName
  scope: secret
  properties: {
    principalId: principalId
    principalType: principalType
    roleDefinitionId: roleDefinitionId
  }
}
