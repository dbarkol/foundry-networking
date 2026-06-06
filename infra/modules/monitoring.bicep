// Log Analytics workspace, workspace-based Application Insights,
// Data Collection Endpoint, and a Data Collection Rule for Linux syslog.
// Public network access is DISABLED on all of them. All ingestion and
// query must come through the AMPLS private endpoint.

@description('Azure region for regional monitoring resources.')
param location string

@description('Base name used to derive child resource names.')
param namePrefix string

@description('Tags applied to all resources.')
param tags object = {}

@description('Optional. Resource ID of a workspace-transformation DCR (kind: WorkspaceTransforms) to link to this workspace. Empty = no link. When set, the workspace will route App* / supported-table ingestion through this DCR for ingestion-time filtering. Only ONE workspace-transformation DCR can be linked per workspace.')
param defaultDcrResourceId string = ''

var workspaceName = '${namePrefix}-law'
var appInsightsName = '${namePrefix}-ai'
var dceName = '${namePrefix}-dce'
var dcrName = '${namePrefix}-syslog-dcr'

resource workspace 'Microsoft.OperationalInsights/workspaces@2022-10-01' = {
  name: workspaceName
  location: location
  tags: tags
  properties: {
    sku: { name: 'PerGB2018' }
    retentionInDays: 30
    publicNetworkAccessForIngestion: 'Disabled'
    publicNetworkAccessForQuery: 'Disabled'
    features: {
      enableLogAccessUsingOnlyResourcePermissions: true
    }
    // Link to a workspace-transformation DCR. This is the ONLY supported
    // mechanism for activating workspace transformations — the legacy
    // `Microsoft.Insights/dataCollectionRuleAssociations` resource (used
    // for VM/agent DCRs) does NOT apply transformations for App* tables.
    // See Foundry-Tracing.md "Redacting prompt and completion content".
    defaultDataCollectionRuleResourceId: empty(defaultDcrResourceId) ? null : defaultDcrResourceId
  }
}

resource appInsights 'Microsoft.Insights/components@2020-02-02' = {
  name: appInsightsName
  location: location
  kind: 'web'
  tags: tags
  properties: {
    Application_Type: 'web'
    WorkspaceResourceId: workspace.id
    // Ingestion MUST be 'Enabled' for Foundry prompt-agent tracing to work.
    // Prompt agents (and other hosted Foundry agent types) execute on
    // Microsoft-managed runtime that runs outside our VNet, so it cannot
    // reach an AMPLS-private ingestion endpoint. Query plane stays private
    // via AMPLS + NSP, which is what blocks data exfil from the public internet.
    // See Foundry-Tracing.md for the full rationale.
    publicNetworkAccessForIngestion: 'Enabled'
    publicNetworkAccessForQuery: 'Disabled'
  }
}

resource dce 'Microsoft.Insights/dataCollectionEndpoints@2022-06-01' = {
  name: dceName
  location: location
  tags: tags
  kind: 'Linux'
  properties: {
    networkAcls: {
      publicNetworkAccess: 'Disabled'
    }
  }
}

resource dcr 'Microsoft.Insights/dataCollectionRules@2022-06-01' = {
  name: dcrName
  location: location
  tags: tags
  kind: 'Linux'
  properties: {
    dataCollectionEndpointId: dce.id
    dataSources: {
      syslog: [
        {
          name: 'syslogDataSource'
          streams: [ 'Microsoft-Syslog' ]
          facilityNames: [
            'auth'
            'authpriv'
            'cron'
            'daemon'
            'kern'
            'local0'
            'local1'
            'local2'
            'local3'
            'local4'
            'local5'
            'local6'
            'local7'
            'mark'
            'news'
            'syslog'
            'user'
            'uucp'
          ]
          logLevels: [ 'Debug', 'Info', 'Notice', 'Warning', 'Error', 'Critical', 'Alert', 'Emergency' ]
        }
      ]
    }
    destinations: {
      logAnalytics: [
        {
          workspaceResourceId: workspace.id
          name: 'lawDest'
        }
      ]
    }
    dataFlows: [
      {
        streams: [ 'Microsoft-Syslog' ]
        destinations: [ 'lawDest' ]
      }
    ]
  }
}

output workspaceId string = workspace.id
output workspaceName string = workspace.name
output workspaceCustomerId string = workspace.properties.customerId
output appInsightsId string = appInsights.id
output appInsightsName string = appInsights.name
output appInsightsConnectionString string = appInsights.properties.ConnectionString
output appInsightsInstrumentationKey string = appInsights.properties.InstrumentationKey
output dceId string = dce.id
output dceName string = dce.name
output dceLogsIngestionEndpoint string = dce.properties.logsIngestion.endpoint
output dcrId string = dcr.id
output dcrName string = dcr.name
