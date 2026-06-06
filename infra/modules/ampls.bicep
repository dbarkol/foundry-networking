// Azure Monitor Private Link Scope (AMPLS, global) + scoped resources for
// the Log Analytics workspace, Application Insights, and DCE.
//
// AMPLS accessMode controls how networks reaching this AMPLS treat OTHER
// Azure Monitor resources outside the scope. It does NOT close off public
// access to the scoped resources themselves — that is done at the resource
// level (publicNetworkAccessFor* on workspace/AI, networkAcls on DCE).

@description('Base name used to derive child resource names.')
param namePrefix string

@description('Tags applied to all resources.')
param tags object = {}

@description('AMPLS ingestion access mode for networks connected via this AMPLS.')
@allowed([ 'Open', 'PrivateOnly' ])
param ingestionAccessMode string = 'Open'

@description('AMPLS query access mode for networks connected via this AMPLS.')
@allowed([ 'Open', 'PrivateOnly' ])
param queryAccessMode string = 'Open'

@description('Resource id of the Log Analytics workspace to scope.')
param workspaceId string

@description('Resource id of the Application Insights component to scope.')
param appInsightsId string

@description('Resource id of the Data Collection Endpoint to scope.')
param dceId string

var amplsName = '${namePrefix}-ampls'

resource ampls 'Microsoft.Insights/privateLinkScopes@2021-07-01-preview' = {
  name: amplsName
  location: 'global'
  tags: tags
  properties: {
    accessModeSettings: {
      ingestionAccessMode: ingestionAccessMode
      queryAccessMode: queryAccessMode
    }
  }
}

resource workspaceLink 'Microsoft.Insights/privateLinkScopes/scopedResources@2021-07-01-preview' = {
  parent: ampls
  name: 'workspace-link'
  properties: {
    linkedResourceId: workspaceId
  }
}

resource appInsightsLink 'Microsoft.Insights/privateLinkScopes/scopedResources@2021-07-01-preview' = {
  parent: ampls
  name: 'appinsights-link'
  properties: {
    linkedResourceId: appInsightsId
  }
  dependsOn: [ workspaceLink ]
}

resource dceLink 'Microsoft.Insights/privateLinkScopes/scopedResources@2021-07-01-preview' = {
  parent: ampls
  name: 'dce-link'
  properties: {
    linkedResourceId: dceId
  }
  dependsOn: [ appInsightsLink ]
}

output amplsId string = ampls.id
output amplsName string = ampls.name
