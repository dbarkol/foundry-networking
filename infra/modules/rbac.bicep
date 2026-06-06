// RBAC assignments for the test VM's system-assigned managed identity:
//   * Cognitive Services OpenAI User on the Foundry account (call
//     gpt-4.1-mini chat completions with an Entra token — this is the role
//     OpenAI inference requires; "Cognitive Services User" alone is not
//     sufficient for the /openai/deployments/*/chat/completions endpoint).
//   * Azure AI User on the Foundry project (use the azure-ai-projects SDK
//     and read project metadata).
//   * Log Analytics Reader on the workspace (run KQL from the VM since
//     public query access is disabled)
//   * Monitoring Reader at the resource group scope so the VM can read
//     resource metadata when troubleshooting

@description('Principal id (object id) of the VM system-assigned identity.')
param vmPrincipalId string

@description('Resource id of the Foundry / Cognitive Services account.')
param foundryId string

@description('Resource id of the Foundry project.')
param projectId string

@description('Resource id of the Log Analytics workspace.')
param workspaceId string

// Role definition ids (subscription-level GUIDs).
var cognitiveServicesOpenAIUser = '5e0bd9bd-7b93-4f28-af87-19fc36ad61bd'
var azureAIUser                 = '53ca6127-db72-4b80-b1b0-d745d6d5456d'
var logAnalyticsReader          = '73c42c96-874c-492b-b04d-ab87d138a893'
var monitoringReader            = '43d0d8ad-25c7-4714-9337-8ba259a9fe05'

resource foundryRef 'Microsoft.CognitiveServices/accounts@2025-04-01-preview' existing = {
  name: last(split(foundryId, '/'))
}

resource projectRef 'Microsoft.CognitiveServices/accounts/projects@2025-04-01-preview' existing = {
  parent: foundryRef
  name: last(split(projectId, '/'))
}

resource workspaceRef 'Microsoft.OperationalInsights/workspaces@2022-10-01' existing = {
  name: last(split(workspaceId, '/'))
}

resource openAiUser 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: foundryRef
  name: guid(foundryRef.id, vmPrincipalId, cognitiveServicesOpenAIUser)
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', cognitiveServicesOpenAIUser)
    principalId: vmPrincipalId
    principalType: 'ServicePrincipal'
  }
}

resource aiUserOnProject 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: projectRef
  name: guid(projectRef.id, vmPrincipalId, azureAIUser)
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', azureAIUser)
    principalId: vmPrincipalId
    principalType: 'ServicePrincipal'
  }
}

resource lawReader 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: workspaceRef
  name: guid(workspaceRef.id, vmPrincipalId, logAnalyticsReader)
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', logAnalyticsReader)
    principalId: vmPrincipalId
    principalType: 'ServicePrincipal'
  }
}

resource monReader 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(resourceGroup().id, vmPrincipalId, monitoringReader)
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', monitoringReader)
    principalId: vmPrincipalId
    principalType: 'ServicePrincipal'
  }
}
