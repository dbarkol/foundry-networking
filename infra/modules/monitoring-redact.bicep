// Workspace transformation DCR that strips Foundry GenAI prompt/completion
// content from App* tables at ingestion time, before they hit LAW storage.
//
// Hosted prompt agents have NO portal toggle to disable content recording
// (verified against Foundry docs as of 2026-06). This DCR is the only
// in-product way to remove that content for hosted-agent workloads.
//
// === How activation works (READ THIS FIRST) ===
// Workspace-transformation DCRs (`kind: WorkspaceTransforms`) are activated
// by setting `defaultDataCollectionRuleResourceId` on the LAW itself — NOT
// by creating a `Microsoft.Insights/dataCollectionRuleAssociations` resource.
// That association resource is for VM/agent DCRs and is silently ignored
// for App* table transformations. The link is set in `monitoring.bicep`
// from `main.bicep` when `redactPromptContent = true`.
//
// Activation can take **up to 60 minutes** after the workspace PATCH lands.
// Source: https://learn.microsoft.com/azure/azure-monitor/app/opentelemetry-filter
//
// === Why this is an allow-list, not a block-list ===
// Azure Monitor DCR transformations support only a small KQL subset.
// Critically: `bag_remove_keys` and `dynamic(...)` literals are NOT
// supported. The only viable approach is to rebuild Properties from
// scratch — we use `pack()` (supported) which preserves type fidelity
// and handles JSON escaping safely. Anything not explicitly listed
// (including the `gen_ai.input.messages` / `gen_ai.output.messages`
// keys that carry conversation content) is dropped on the floor.
//
// === What survives ===
// Top-level columns are untouched: Name (e.g. "invoke_agent DemoAgent:3"),
// DurationMs, Success, ResultCode, OperationId, ParentId, AppRoleName,
// TimeGenerated. The Foundry portal Traces tab shows the span tree and
// per-span latency. The "Input + Output" panel will be empty.
//
// === Caveats ===
// - Workspace transformations apply at INGESTION only. Records ingested
//   before this is enabled are untouched. Purge via LAW table purge if
//   needed.
// - One workspace transformation DCR per workspace. If you add other
//   transformations later, merge them into this DCR's dataFlows.

@description('Azure region.')
param location string

@description('Deterministic DCR name. Must match what main.bicep computes so the workspace link in monitoring.bicep resolves to this DCR.')
param dcrName string

@description('Tags applied to the DCR.')
param tags object

@description('Name of the LAW the App Insights component is workspace-based on.')
param workspaceName string

resource workspace 'Microsoft.OperationalInsights/workspaces@2022-10-01' existing = {
  name: workspaceName
}

var workspaceDestName = 'lawDest'

// Allow-list of Properties keys preserved on AppDependencies (Foundry agent
// spans). All other keys — including gen_ai.input.messages and
// gen_ai.output.messages — are discarded. `pack()` is supported in DCR
// transformation KQL and handles JSON escaping correctly for arbitrary
// values (no manual string concatenation, no \" / \\ pitfalls).
// Bracket notation is required for source keys containing dots.
var depsRebuildKql = '''
extend Properties = pack(
  'gen_ai.provider.name',         Properties['gen_ai.provider.name'],
  'gen_ai.request.model',         Properties['gen_ai.request.model'],
  'gen_ai.response.model',        Properties['gen_ai.response.model'],
  'gen_ai.response.id',           Properties['gen_ai.response.id'],
  'gen_ai.operation.name',        Properties['gen_ai.operation.name'],
  'gen_ai.agent.name',            Properties['gen_ai.agent.name'],
  'gen_ai.agent.version',         Properties['gen_ai.agent.version'],
  'gen_ai.agent.id',              Properties['gen_ai.agent.id'],
  'gen_ai.conversation.id',       Properties['gen_ai.conversation.id'],
  'gen_ai.azure_ai_project.id',   Properties['gen_ai.azure_ai_project.id'],
  'span_type',                    Properties['span_type'],
  'microsoft.foundry',            Properties['microsoft.foundry'],
  '_MS.ResourceAttributeId',      Properties['_MS.ResourceAttributeId']
)
'''

// AppTraces / AppRequests aren't populated by hosted prompt agents today but
// could be in the future; clear Properties entirely as defense-in-depth.
var emptyPropsKql = 'extend Properties = parse_json(\'{}\')'

resource redactDcr 'Microsoft.Insights/dataCollectionRules@2023-03-11' = {
  name: dcrName
  location: location
  tags: tags
  kind: 'WorkspaceTransforms'
  properties: {
    dataSources: {}
    destinations: {
      logAnalytics: [
        {
          workspaceResourceId: workspace.id
          name: workspaceDestName
        }
      ]
    }
    dataFlows: [
      {
        streams: [ 'Microsoft-Table-AppDependencies' ]
        destinations: [ workspaceDestName ]
        transformKql: 'source | ${depsRebuildKql}'
      }
      {
        streams: [ 'Microsoft-Table-AppTraces' ]
        destinations: [ workspaceDestName ]
        transformKql: 'source | ${emptyPropsKql}'
      }
      {
        streams: [ 'Microsoft-Table-AppRequests' ]
        destinations: [ workspaceDestName ]
        transformKql: 'source | ${emptyPropsKql}'
      }
    ]
  }
}

output redactDcrId string = redactDcr.id
output redactDcrName string = redactDcr.name
