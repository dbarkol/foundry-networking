// Subscription-scope entry. Creates the resource group and composes all
// modules. Ordering is enforced via module references and explicit dependsOn
// where Bicep can't infer.

targetScope = 'subscription'

@minLength(1)
@maxLength(64)
@description('azd environment name. Used as a name prefix for all resources.')
param environmentName string

@description('Azure region for regional resources.')
param location string

@description('AMPLS ingestion access mode (Open or PrivateOnly).')
@allowed([ 'Open', 'PrivateOnly' ])
param accessMode string = 'Open'

@description('Admin username for the test VM.')
param adminUsername string = 'azureuser'

@description('SSH public key for the admin user on the test VM.')
@secure()
param sshPublicKey string

@description('Foundry model name to deploy.')
param foundryModelName string = 'gpt-4.1-mini'

@description('Foundry model version.')
param foundryModelVersion string = '2025-04-14'

@description('Foundry model SKU name.')
param foundryModelSkuName string = 'GlobalStandard'

@description('Foundry model capacity (thousands of TPM).')
@minValue(1)
param foundryModelCapacity int = 10

@description('Model format passed to the deployment. Usually "OpenAI"; use "OpenAI-OSS" for open-weight models such as gpt-oss-120b.')
param foundryModelFormat string = 'OpenAI'

@description('Pre-provision Foundry Agent backing services (Cosmos + Storage + AI Search) and their private endpoints, project connections, and pre-caphost RBAC. Default true — no extra agent runtime cost until enableAgents is also set.')
param enableAgentBackingServices bool = true

@description('Create the Foundry account + project capability hosts (turns the project into a working agent runtime). Requires enableAgentBackingServices = true. Default false so you can stage cost.')
param enableAgents bool = false

@description('AI Search SKU. basic is the cheapest tier that supports private endpoints.')
@allowed([ 'basic', 'standard', 'standard2', 'standard3' ])
param searchSku string = 'basic'

@description('Include AI Search in the backing services. Set false to skip Search only (Cosmos + Storage still deploy). AI Search Basic capacity is sometimes exhausted in popular regions. Required for capability host / agents.')
param enableSearch bool = true

@description('Optional tags applied to all resources.')
param tags object = {
  'azd-env-name': environmentName
  workload: 'ampls-foundry'
}

@description('Strip Foundry GenAI prompt/completion content from App* tables before they land in LAW. Use when you want tracing (spans, latency, token counts) but cannot allow conversation content to be stored. Hosted prompt agents do not have a portal toggle for this. Default false to preserve current behavior — see Foundry-Tracing.md for details.')
param redactPromptContent bool = false

var namePrefix = take(toLower(replace(environmentName, '_', '-')), 18)
var rgName = 'rg-${environmentName}'
// Foundry custom subdomain must be globally unique; pad with a short hash.
var foundrySubdomain = toLower('${namePrefix}-aif-${uniqueString(subscription().id, environmentName)}')

// Backing-service names (derived from environmentName so they're stable
// across deployments). Storage account name has the strictest constraints
// (3-24 chars, alphanumeric lowercase only) so we sanitise hardest there.
var backingHash = take(uniqueString(subscription().id, environmentName, 'agents'), 6)
var namePrefixAlnum = toLower(replace(replace(environmentName, '_', ''), '-', ''))
var storagePrefix = take(namePrefixAlnum, 16)
var cosmosDBName = take('${namePrefix}-cosmos-${backingHash}', 44)
var storageName  = take('${storagePrefix}${backingHash}st', 24)
var searchName   = take('${namePrefix}-search-${backingHash}', 60)

resource rg 'Microsoft.Resources/resourceGroups@2024-03-01' = {
  name: rgName
  location: location
  tags: tags
}

// Deterministic redact-DCR name and resource ID, computed up front so the
// workspace (in `monitoring`) can reference it for `defaultDataCollectionRuleResourceId`
// without depending on the `monitoringRedact` module output. ARM accepts the
// forward reference because the property is just a string; both resources
// finish provisioning within the same deployment.
var redactDcrName = '${namePrefix}-redact-genai-content'
var redactDcrId = redactPromptContent
  ? '${subscription().id}/resourceGroups/${rgName}/providers/Microsoft.Insights/dataCollectionRules/${redactDcrName}'
  : ''

module network 'modules/network.bicep' = {
  scope: rg
  name: 'network'
  params: {
    location: location
    namePrefix: namePrefix
    tags: tags
  }
}

module monitoring 'modules/monitoring.bicep' = {
  scope: rg
  name: 'monitoring'
  params: {
    location: location
    namePrefix: namePrefix
    tags: tags
    // Link workspace to the redact DCR (created in monitoringRedact). Empty
    // when redactPromptContent=false, which leaves the workspace unlinked.
    defaultDcrResourceId: redactDcrId
  }
}

module monitoringRedact 'modules/monitoring-redact.bicep' = if (redactPromptContent) {
  scope: rg
  name: 'monitoring-redact'
  params: {
    location: location
    dcrName: redactDcrName
    tags: tags
    workspaceName: monitoring.outputs.workspaceName
  }
}

module ampls 'modules/ampls.bicep' = {
  scope: rg
  name: 'ampls'
  params: {
    namePrefix: namePrefix
    tags: tags
    ingestionAccessMode: accessMode
    queryAccessMode: accessMode
    workspaceId: monitoring.outputs.workspaceId
    appInsightsId: monitoring.outputs.appInsightsId
    dceId: monitoring.outputs.dceId
  }
}

module amplsPe 'modules/ampls-private-endpoint.bicep' = {
  scope: rg
  name: 'ampls-pe'
  params: {
    location: location
    namePrefix: namePrefix
    tags: tags
    amplsId: ampls.outputs.amplsId
    privateEndpointsSubnetId: network.outputs.privateEndpointsSubnetId
    vnetId: network.outputs.vnetId
  }
}

module foundry 'modules/foundry.bicep' = {
  scope: rg
  name: 'foundry'
  params: {
    location: location
    namePrefix: namePrefix
    tags: tags
    customSubdomain: foundrySubdomain
    appInsightsId: monitoring.outputs.appInsightsId
    workspaceId: monitoring.outputs.workspaceId
    modelName: foundryModelName
    modelVersion: foundryModelVersion
    modelSkuName: foundryModelSkuName
    modelCapacity: foundryModelCapacity
    modelFormat: foundryModelFormat
    // networkInjections is required for Standard Agent Setup and triggers a
    // subscription-level feature check. Only enable when actually turning
    // agents on (caphost module also gated on the same flag).
    agentSubnetId: network.outputs.agentSubnetId
    enableNetworkInjection: enableAgents
  }
}

module foundryPe 'modules/foundry-private-endpoint.bicep' = {
  scope: rg
  name: 'foundry-pe'
  params: {
    location: location
    namePrefix: namePrefix
    tags: tags
    foundryId: foundry.outputs.foundryId
    privateEndpointsSubnetId: network.outputs.privateEndpointsSubnetId
    vnetId: network.outputs.vnetId
  }
}

// ---------- Agent backing services (Cosmos / Storage / Search) ----------

module cosmos 'modules/cosmos.bicep' = if (enableAgentBackingServices) {
  scope: rg
  name: 'cosmos'
  params: {
    location: location
    cosmosDBName: cosmosDBName
    tags: tags
  }
}

module storage 'modules/storage.bicep' = if (enableAgentBackingServices) {
  scope: rg
  name: 'storage'
  params: {
    location: location
    storageName: storageName
    tags: tags
  }
}

module search 'modules/search.bicep' = if (enableAgentBackingServices && enableSearch) {
  scope: rg
  name: 'search'
  params: {
    location: location
    searchName: searchName
    sku: searchSku
    tags: tags
  }
}

module backingPes 'modules/backing-private-endpoints.bicep' = if (enableAgentBackingServices) {
  scope: rg
  name: 'backing-pes'
  params: {
    location: location
    namePrefix: namePrefix
    tags: tags
    vnetId: network.outputs.vnetId
    privateEndpointsSubnetId: network.outputs.privateEndpointsSubnetId
    cosmosDBName: cosmosDBName
    storageName: storageName
    searchName: enableSearch ? searchName : ''
  }
  // amplsPe already creates the privatelink.blob.* DNS zone — serialize to
  // avoid concurrent-upsert conflict on the same DNS zone resource.
  dependsOn: enableSearch ? [ cosmos, storage, search, amplsPe ] : [ cosmos, storage, amplsPe ]
}

module foundryProject 'modules/foundry-project.bicep' = {
  scope: rg
  name: 'foundry-project'
  params: {
    location: location
    namePrefix: namePrefix
    tags: tags
    accountName: foundry.outputs.foundryName
    cosmosDBName: enableAgentBackingServices ? cosmosDBName : ''
    storageName:  enableAgentBackingServices ? storageName : ''
    searchName:   (enableAgentBackingServices && enableSearch) ? searchName : ''
    appInsightsName: monitoring.outputs.appInsightsName
  }
  // Project connections need the backing services to exist + be reachable.
  dependsOn: enableAgentBackingServices ? [ backingPes ] : []
}

module agentRbac 'modules/agent-rbac.bicep' = if (enableAgentBackingServices) {
  scope: rg
  name: 'agent-rbac'
  params: {
    projectPrincipalId: foundryProject.outputs.projectPrincipalId
    cosmosDBName: cosmosDBName
    storageName: storageName
    searchName: enableSearch ? searchName : ''
  }
}

module caphost 'modules/caphost.bicep' = if (enableAgents && enableAgentBackingServices && enableSearch) {
  scope: rg
  name: 'caphost'
  params: {
    accountName: foundry.outputs.foundryName
    projectName: foundryProject.outputs.projectName
    agentSubnetId: network.outputs.agentSubnetId
    cosmosDBName: cosmosDBName
    storageName: storageName
    cosmosConnectionName:  foundryProject.outputs.cosmosConnectionName
    storageConnectionName: foundryProject.outputs.storageConnectionName
    searchConnectionName:  foundryProject.outputs.searchConnectionName
    projectPrincipalId: foundryProject.outputs.projectPrincipalId
    projectWorkspaceId: foundryProject.outputs.projectWorkspaceId
  }
  // Caphost provisioning calls the backing services with the project SMI,
  // so all four RBAC assignments must be in place first. Note that ARM
  // role-assignment completion ≠ data-plane propagation; if caphost 403s,
  // wait ~60s and re-deploy (idempotent).
  dependsOn: [ agentRbac, foundryPe ]
}

module bastion 'modules/bastion.bicep' = {
  scope: rg
  name: 'bastion'
  params: {
    location: location
    namePrefix: namePrefix
    tags: tags
    bastionSubnetId: network.outputs.bastionSubnetId
  }
}

module vm 'modules/vm.bicep' = {
  scope: rg
  name: 'vm'
  params: {
    location: location
    namePrefix: namePrefix
    tags: tags
    workloadSubnetId: network.outputs.workloadSubnetId
    dcrId: monitoring.outputs.dcrId
    adminUsername: adminUsername
    sshPublicKey: sshPublicKey
  }
}

module rbac 'modules/rbac.bicep' = {
  scope: rg
  name: 'rbac'
  params: {
    vmPrincipalId: vm.outputs.vmPrincipalId
    foundryId: foundry.outputs.foundryId
    workspaceId: monitoring.outputs.workspaceId
    projectId: foundryProject.outputs.projectId
  }
}

// Outputs (also surfaced as azd env values for the README test workflow)
output AZURE_LOCATION string = location
output AZURE_RESOURCE_GROUP string = rg.name
output VNET_NAME string = network.outputs.vnetName
output BASTION_NAME string = bastion.outputs.bastionName
output VM_NAME string = vm.outputs.vmName
output VM_PRIVATE_IP string = vm.outputs.vmPrivateIp
output VM_ADMIN_USERNAME string = adminUsername
output LOG_ANALYTICS_WORKSPACE_NAME string = monitoring.outputs.workspaceName
output LOG_ANALYTICS_WORKSPACE_CUSTOMER_ID string = monitoring.outputs.workspaceCustomerId
output APPINSIGHTS_NAME string = monitoring.outputs.appInsightsName
output APPLICATIONINSIGHTS_CONNECTION_STRING string = monitoring.outputs.appInsightsConnectionString
output DCE_LOGS_INGESTION_ENDPOINT string = monitoring.outputs.dceLogsIngestionEndpoint
output AMPLS_NAME string = ampls.outputs.amplsName
output AMPLS_ACCESS_MODE string = accessMode
output FOUNDRY_NAME string = foundry.outputs.foundryName
output FOUNDRY_ENDPOINT string = foundry.outputs.foundryEndpoint
output FOUNDRY_OPENAI_ENDPOINT string = foundry.outputs.foundryOpenAiEndpoint
output FOUNDRY_MODEL_DEPLOYMENT_NAME string = foundry.outputs.modelDeploymentName
output FOUNDRY_PROJECT_NAME string = foundryProject.outputs.projectName
output FOUNDRY_PROJECT_ENDPOINT string = foundryProject.outputs.projectEndpoint
output AGENT_BACKING_ENABLED bool = enableAgentBackingServices
output AGENTS_ENABLED bool = enableAgents
output COSMOS_DB_NAME string = enableAgentBackingServices ? cosmosDBName : ''
output STORAGE_ACCOUNT_NAME string = enableAgentBackingServices ? storageName : ''
output SEARCH_SERVICE_NAME string = (enableAgentBackingServices && enableSearch) ? searchName : ''
output SEARCH_ENABLED bool = enableSearch
