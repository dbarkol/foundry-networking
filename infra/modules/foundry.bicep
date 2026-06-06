// Azure AI Foundry account (Cognitive Services kind: AIServices) with
// public network access disabled, a custom subdomain (required for PE),
// system-assigned identity, and a gpt-4.1-mini model deployment.
//
// We also wire Application Insights diagnostics on the account so request
// telemetry and metrics flow to the (private) App Insights / workspace.

@description('Azure region for the Foundry account.')
param location string

@description('Base name used to derive child resource names.')
param namePrefix string

@description('Tags applied to all resources.')
param tags object = {}

@description('Custom subdomain for the Foundry account. Must be globally unique.')
param customSubdomain string

@description('Application Insights resource id used for diagnostic settings.')
param appInsightsId string

@description('Log Analytics workspace resource id used for diagnostic settings.')
param workspaceId string

@description('Foundry model name to deploy.')
param modelName string = 'gpt-4.1-mini'

@description('Foundry model version.')
param modelVersion string = '2025-04-14'

@description('Model deployment SKU name (e.g., GlobalStandard, Standard).')
param modelSkuName string = 'GlobalStandard'

@description('Model deployment capacity in thousands of tokens-per-minute.')
@minValue(1)
param modelCapacity int = 10

@description('Model format. Usually "OpenAI". Use "OpenAI-OSS" for open-weight models such as gpt-oss-120b. Other formats: Meta, Microsoft, Mistral AI, Cohere, AI21, Core42, etc.')
param modelFormat string = 'OpenAI'

@description('Optional. Resource ID of the agent-delegated subnet. When set, networkInjections binds the Foundry account to it (required for Standard Agent Setup).')
param agentSubnetId string = ''

@description('Whether to set networkInjections on the Foundry account. Requires the subscription to be allowlisted for "CapabilityHost with CustomerSubnet". Default false — set true only when you are ready to enable agents.')
param enableNetworkInjection bool = false

var foundryName = '${namePrefix}-aif'
var injectNetwork = enableNetworkInjection && !empty(agentSubnetId)

resource foundry 'Microsoft.CognitiveServices/accounts@2025-04-01-preview' = {
  name: foundryName
  location: location
  tags: tags
  kind: 'AIServices'
  sku: { name: 'S0' }
  identity: { type: 'SystemAssigned' }
  properties: {
    // allowProjectManagement is required to attach Foundry projects
    // (Microsoft.CognitiveServices/accounts/projects) to this account.
    allowProjectManagement: true
    customSubDomainName: customSubdomain
    publicNetworkAccess: 'Disabled'
    disableLocalAuth: false
    networkAcls: {
      defaultAction: 'Deny'
      virtualNetworkRules: []
      ipRules: []
    }
    // networkInjections is required for Standard Agent Setup, but it triggers
    // a subscription-level allowlist check ("CapabilityHost with CustomerSubnet")
    // even when no capability host exists yet. Only set it when the caller
    // explicitly opts in via enableNetworkInjection — flipping it on later is
    // an in-place property update, not a recreate.
    networkInjections: injectNetwork ? [
      {
        scenario: 'agent'
        subnetArmId: agentSubnetId
        useMicrosoftManagedNetwork: false
      }
    ] : null
  }
}

resource modelDeployment 'Microsoft.CognitiveServices/accounts/deployments@2025-04-01-preview' = {
  parent: foundry
  name: modelName
  sku: {
    name: modelSkuName
    capacity: modelCapacity
  }
  properties: {
    model: {
      format: modelFormat
      name: modelName
      version: modelVersion
    }
    raiPolicyName: 'Microsoft.DefaultV2'
    versionUpgradeOption: 'OnceNewDefaultVersionAvailable'
  }
}

// Send Foundry account diagnostics (Audit, RequestResponse, Trace) and all
// metrics to the App Insights-backed Log Analytics workspace. Because the
// workspace is scoped into AMPLS and public access is disabled, the
// telemetry path itself rides Private Link.
resource foundryDiag 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  scope: foundry
  name: 'foundry-to-law'
  properties: {
    workspaceId: workspaceId
    logs: [
      { categoryGroup: 'allLogs', enabled: true }
    ]
    metrics: [
      { category: 'AllMetrics', enabled: true }
    ]
  }
}

output foundryId string = foundry.id
output foundryName string = foundry.name
output foundryEndpoint string = foundry.properties.endpoint
output foundryOpenAiEndpoint string = 'https://${customSubdomain}.openai.azure.com/'
output modelDeploymentName string = modelDeployment.name
// Reference appInsightsId so unused-parameter warnings don't fire; the value
// is intentionally available for downstream wiring (Foundry → project
// connection) if a project is added later.
output appInsightsIdEcho string = appInsightsId
