# Foundry Agent Tracing with Application Insights

This stack provisions a private Application Insights resource and (as of
this commit) wires it as a **project connection** to the Foundry project
automatically. That enables the Foundry Agents tracing experience — every
agent run produces full distributed traces with prompt, tool call, token
usage, and latency spans, visible inside the Foundry Portal *and* in
Application Insights / Log Analytics.

This guide explains what gets configured, how to verify it after deploy,
and how to query the trace data — all over private networking.

> **⚠️ Hard requirement for prompt agents:**
> App Insights **`publicNetworkAccessForIngestion` must be `Enabled`**.
> Prompt agents execute on Microsoft-managed runtime that runs outside
> your VNet and cannot reach an AMPLS-private ingestion endpoint. With
> ingestion `Disabled`, the Tracing tab stays empty no matter how many
> agent runs you do (verified empirically with a prompt agent on
> `gpt-4.1-mini` in westus3). This stack ships with ingestion `Enabled`
> and query `Disabled` — the data-exfil-relevant boundary is the query
> plane, which remains AMPLS-only. See [*Why ingestion is public*](#why-ingestion-is-public-and-why-thats-still-secure)
> below for the full tradeoff and stricter alternatives.
>
> Other Foundry agent types that run on the same hosted runtime are
> almost certainly subject to the same constraint, but only the prompt
> agent path has been confirmed in this stack.

> **Related guides**
> - [`README.md`](./README.md) — deploy this stack with `azd up`
> - [`Networking.md`](./Networking.md) — what's locked down (PEs, DNS zones, AMPLS)
> - [`Bastion-VM-Access.md`](./Bastion-VM-Access.md) — how to reach the Foundry portal + VM through the VNet

---

## What this stack configures for tracing

| Piece | Resource | How it gets there |
|---|---|---|
| Application Insights component | `<env>-ai` (workspace-based, **ingestion public / query private**) | `infra/modules/monitoring.bicep` |
| Backing Log Analytics workspace | `<env>-law` (ingestion & query both private) | `infra/modules/monitoring.bicep` |
| AMPLS-scoped resource link | Adds App Insights + LAW to `<env>-ampls` | `infra/modules/ampls.bicep` |
| AMPLS private endpoint | `<env>-ampls-pe` in `private-endpoints` subnet | `infra/modules/ampls-private-endpoint.bicep` |
| Private DNS zones | `monitor.azure.com`, `oms.opinsights.azure.com`, `ods.opinsights.azure.com`, `agentsvc.azure-automation.net`, `blob.core.windows.net` | `infra/modules/network.bicep` |
| **Foundry project connection of category `AppInsights`** | `<env>-ai-connection` on `<env>-proj` | `infra/modules/foundry-project.bicep` (when `appInsightsName` is provided) |

That last row is the new piece. Without it, the Foundry portal shows the
"Create or connect an App Insights resource to enable tracing" banner on
the Tracing tab, and the Agent SDK has no telemetry sink.

The connection uses `authType: ApiKey` with `credentials.key` set to the
App Insights **connection string**. Foundry's Agent runtime uses that
connection string to push OpenTelemetry spans to App Insights, which lands
the data in the workspace-based LAW.

---

## How traces reach Log Analytics (data path)

```
┌─────────────────────────┐
│  Foundry Agents runtime │  (Microsoft-managed compute, NOT in your VNet)
└─────────────┬───────────┘
              │ OTLP spans, tagged with project connection string
              ▼
┌─────────────────────────┐
│  App Insights ingestion │  publicNetworkAccessForIngestion: Enabled
│  endpoint               │  (reached over Microsoft's public ingestion DNS)
└─────────────┬───────────┘
              │ workspace-based: writes directly to LAW
              ▼
┌─────────────────────────┐
│  Log Analytics workspace│  publicNetworkAccessForQuery: Disabled
│  AppDependencies        │  query reachable only from inside the VNet
│  AppTraces / AppRequests│  (e.g. VM via Bastion). Public query → HTTP 403.
└─────────────────────────┘
```

### Why ingestion is public (and why that's still secure)

**Prompt agents** (and other hosted Foundry agent types) execute on
**Microsoft-managed** compute — not in your VNet. When
`publicNetworkAccessForIngestion` is `Disabled`, the App Insights ingest
endpoint accepts data only over an AMPLS private endpoint, which the
managed runtime cannot reach. **Result: zero traces.** (We verified this
empirically — the Tracing tab stayed empty until we flipped ingestion to
`Enabled`, after which `AppDependencies` immediately populated with
`invoke_agent` and `chat <model>` spans from our prompt agent.)

Keeping **ingestion public + query private** is the right tradeoff because:

1. **The data-exfil risk lives on the query plane.** Ingestion is
   write-only and authenticated to a specific resource. Query is the read
   path — that's what we lock down to the VNet via AMPLS + NSP.
2. **Ingestion is still auth'd**, not anonymous. Spans must carry the
   project's connection-string key.
3. **The query plane proof still holds:** running an `AppDependencies`
   query from your laptop returns HTTP 403 with an NSP denial mentioning
   your public IP. Run the same query from the VM — it works. Same data,
   two network paths, two outcomes.

### Alternatives if you need fully-private ingestion

| Option | What it requires | Tradeoff |
|---|---|---|
| **Subnet-injected agent runtime** (`ENABLE_AGENTS=true` + Caphost) | `CapabilityHost` + `CustomerSubnet` feature flag allowlisted on subscription | Agent runtime runs in your VNet → can reach private ingestion. Applies to non-prompt agent paths. |
| **Client-side tracing only** | Your own SDK app on the VM using OpenTelemetry → App Insights | Only traces calls *you* make from the SDK; **prompt agent runs won't be traced** because they execute on the managed runtime |
| **Accept no prompt-agent tracing** | Set ingestion back to `Disabled` in `monitoring.bicep` | Strictest posture; Tracing tab stays empty for prompt agents |

This stack chooses **Option A** (public ingest, private query). Change it
by editing `publicNetworkAccessForIngestion` in `infra/modules/monitoring.bicep`.

---

## Verify tracing is wired up after deploy

### 1. Confirm the project connection exists

```bash
RG=$(azd env get-value AZURE_RESOURCE_GROUP)
FOUNDRY=$(azd env get-value FOUNDRY_NAME)
PROJ=$(echo "$(azd env get-value FOUNDRY_PROJECT_ENDPOINT)" | awk -F/ '{print $NF}')

az rest --method get --url "https://management.azure.com/subscriptions/$(az account show --query id -o tsv)/resourceGroups/$RG/providers/Microsoft.CognitiveServices/accounts/$FOUNDRY/projects/$PROJ/connections?api-version=2025-04-01-preview" \
  --query "value[?properties.category=='AppInsights'].{name:name, category:properties.category, authType:properties.authType, sharedToAll:properties.isSharedToAll}" -o table
```

Expected output:

```
Name                       Category      AuthType    SharedToAll
-------------------------  ------------  ----------  -----------
<env>-ai-connection        AppInsights   ApiKey      True
```

### 2. Confirm the portal banner is gone

Open the Foundry portal (see [`Bastion-VM-Access.md`](./Bastion-VM-Access.md)):

1. Navigate to your project → **Tracing** (left nav).
2. The purple **"Create or connect an App Insights resource to enable
   tracing"** banner should be gone. The Tracing dashboard should show
   "No traces yet" until you run an agent.

### 3. Run an agent and check the dashboard

1. Project → **Agents** → pick or create an agent → **Playground**.
2. Send a prompt: `Tell me a one-sentence joke about Bicep.`
3. Back to **Tracing** → refresh. Within ~60 seconds you'll see a trace
   row. Click into it for spans like `invoke_agent <AgentName>:<version>`
   and `chat <model-name>`, each with request payload, response, token
   usage, and latency.

> **Where the spans land:** Foundry emits OpenTelemetry **client** spans,
> which the App Insights schema maps to the **`AppDependencies`** table —
> not `AppTraces`. The portal's Tracing tab queries dependencies under
> the hood. When debugging via KQL, query `AppDependencies` first.

---

## Query the trace data from the VM (over Private Link)

Because the workspace is locked to private access, you can't query from
your laptop directly (you'll get HTTP 403 with an NSP denial mentioning
your laptop's public IP). You query from the VM instead.

SSH into the VM (per `Bastion-VM-Access.md`), then:

```bash
# Find your workspace customerId
WORKSPACE_ID=$(az monitor log-analytics workspace show \
  -g $(azd env get-value AZURE_RESOURCE_GROUP) \
  -n $(azd env get-value LOG_ANALYTICS_WORKSPACE_NAME) \
  --query customerId -o tsv)

# Foundry agent runs — this is the primary table for managed-runtime tracing
az monitor log-analytics query -w $WORKSPACE_ID --analytics-query "
AppDependencies
| where TimeGenerated > ago(1h)
| where AppRoleName == 'responsesapi'
| project TimeGenerated, Name, DurationMs, ResultCode, Success, OperationId
| order by TimeGenerated desc
| take 20
" -o table

# Per-operation latency summary across all dependency calls
az monitor log-analytics query -w $WORKSPACE_ID --analytics-query "
AppDependencies
| where TimeGenerated > ago(1h)
| summarize Count=count(), AvgMs=avg(DurationMs), P95Ms=percentile(DurationMs, 95) by Name
| order by Count desc
" -o table

# What tables have data? (sanity check)
az monitor log-analytics query -w $WORKSPACE_ID --analytics-query "
union withsource=Tbl App*
| where TimeGenerated > ago(1h)
| summarize Count=count() by Tbl
" -o table
```

If any of these return zero rows but you've run an agent: wait another
30–60 seconds (App Insights ingestion buffers in 30-second windows).

---

## Prove the privacy claim — public query is refused

From your **laptop** (not via the VM), run a workspace query:

```bash
WORKSPACE_ID=$(az monitor log-analytics workspace show -g $(azd env get-value AZURE_RESOURCE_GROUP) -n $(azd env get-value LOG_ANALYTICS_WORKSPACE_NAME) --query customerId -o tsv)
az monitor log-analytics query -w $WORKSPACE_ID --analytics-query "AppDependencies | take 1"
```

Expected response:

```
(InsufficientAccessError) Access to workspace '<env>-law' from '<your-IP>'
is denied. ... publicNetworkAccessForQuery is disabled ...
```

That is **the** test that the lockdown is working — same query, same
identity, two different network paths, two different outcomes. Run it
again from the VM (via Bastion) and the same query returns rows.

> **Note on ingestion:** this stack intentionally leaves App Insights
> `publicNetworkAccessForIngestion=Enabled` so the Microsoft-managed
> Foundry Agents runtime can post traces (see *"Why ingestion is public"*
> above). The data-exfil-relevant boundary is the **query** plane, which
> stays private. LAW itself has both planes private.

---

## Redacting prompt and completion content (`redactPromptContent`)

A common requirement: *"I want Foundry tracing for debugging
agent behavior, but conversation content (user prompts, model outputs,
tool arguments) must never land in Application Insights."*

For **hosted prompt agents** there is **no portal toggle** to disable
just content recording — verified against the Foundry docs and confirmed
empirically by walking the Foundry portal **Build → DemoAgent → Traces**
tab on a live deployment. The only documented "off switch" for hosted
agents is to disconnect Application Insights entirely, which loses all
tracing.

This stack ships an opt-in **ingestion-time redaction** path that solves
this without losing tracing:

```bash
azd env set REDACT_PROMPT_CONTENT true
azd up
```

(Default is `false` — current behavior preserved.)

### What it does

Adds a **workspace transformation DCR** (`<env>-redact-genai-content`) of
`kind: WorkspaceTransforms` and links it to the LAW. The transformation
runs server-side at ingestion and rebuilds the `Properties` `dynamic`
column on each `App*` row with only an **allow-list** of safe metadata
keys — discarding anything not explicitly listed (including the GenAI
content keys) **before** records land in storage:

```kusto
source | extend Properties = pack(
  'gen_ai.provider.name',       Properties['gen_ai.provider.name'],
  'gen_ai.request.model',       Properties['gen_ai.request.model'],
  'gen_ai.response.model',      Properties['gen_ai.response.model'],
  'gen_ai.operation.name',      Properties['gen_ai.operation.name'],
  'gen_ai.agent.name',          Properties['gen_ai.agent.name'],
  // ...other safe keys (agent.version, agent.id, conversation.id, etc.)
)
```

> **Why allow-list, not block-list?** Azure Monitor DCR transformations
> support only a small KQL subset. Critically, `bag_remove_keys()` and
> `dynamic([...])` literals are **NOT supported** in transformations, so a
> block-list approach (`bag_remove_keys(Properties, dynamic([...]))`)
> silently fails to parse and the transformation never runs. The only
> viable approach is to rebuild `Properties` from scratch — `pack()` is
> supported and handles JSON encoding safely.
> ([Supported KQL features](https://learn.microsoft.com/azure/azure-monitor/data-collection/data-collection-transformations-kql))

The Foundry hosted prompt-agent runtime emits content under
`gen_ai.input.messages` and `gen_ai.output.messages` today (verified live).
Because these keys are not in the allow-list, they are dropped — along
with any future content keys the runtime might switch to (e.g. OTel GenAI
`gen_ai.prompt` / `gen_ai.completion` or OpenInference `input.value` /
`output.value`). `AppTraces` and `AppRequests` get `Properties` cleared
entirely as defense-in-depth.

### How activation works (important)

Workspace-transformation DCRs are **activated by setting
`defaultDataCollectionRuleResourceId` on the Log Analytics workspace
itself** — not by creating a `Microsoft.Insights/dataCollectionRuleAssociations`
resource. That association resource is for VM/agent DCRs and is silently
ignored for App* table transformations (we tried this first and watched
ingestion continue unfiltered for 5+ hours).

This stack handles the link automatically:

1. `monitoring-redact.bicep` creates the DCR (`kind: WorkspaceTransforms`)
2. `monitoring.bicep` sets `properties.defaultDataCollectionRuleResourceId`
   on the workspace, pointing at the DCR resource ID

Per Microsoft docs: **activation can take up to 60 minutes** after the
workspace PATCH lands. During that window, fresh telemetry will continue
to arrive with full content — that is **not** a failure.
([source](https://learn.microsoft.com/azure/azure-monitor/app/opentelemetry-filter#filter-telemetry-at-ingestion-using-data-collection-rules))

Each workspace can be linked to exactly **one** workspace-transformation
DCR. If you want to add other transformations later (e.g. to filter noisy
`AppMetrics`), merge them into this DCR's `dataFlows` array rather than
creating a second DCR.

### What's still in the trace

Everything **except** message content:

| Preserved | Stripped |
|---|---|
| Span tree (`invoke_agent` → `chat <model>`) | User prompt text |
| Per-span latency, success, error code | Model response text |
| Token usage (input / output / total) | Tool call arguments |
| Model name, model version, agent name, agent version, agent ID | Tool call results |
| Conversation ID, response ID, project ID | Content-filter offsets (kept; offsets only, not text) |
| Operation status & timing | |

The Foundry portal Traces tab continues to show the span tree, durations,
and token counts. The **Input + Output** panel on each span shows empty
or null. The Trajectories list view is unaffected.

### How to verify

> ⚠️ **Activation latency.** Per Microsoft docs, a workspace transformation DCR
> **can take up to 60 minutes to activate** after the workspace is linked
> to it. In our own testing, activation hit at ~35 minutes — your mileage
> may vary. Don't conclude redaction is broken until you've waited at
> least an hour after the last `azd provision`. During that window, fresh
> telemetry will still arrive in `AppDependencies` with the full
> `gen_ai.input.messages` / `gen_ai.output.messages` payload — that is
> **not** a failure.

After `azd up` with the flag on, wait **at least 60 minutes**, send a fresh
agent prompt, wait another ~90s for ingestion, then from the VM (or via
the bastion SOCKS tunnel — query plane is private):

```bash
WORKSPACE_ID=$(az monitor log-analytics workspace show \
  -g $(azd env get-value AZURE_RESOURCE_GROUP) \
  -n $(azd env get-value LOG_ANALYTICS_WORKSPACE_NAME) \
  --query customerId -o tsv)

# Should return rows but with NO gen_ai.input.messages / gen_ai.output.messages
az monitor log-analytics query -w $WORKSPACE_ID --analytics-query "
AppDependencies
| where TimeGenerated > ago(15m)
| where Name startswith 'invoke_agent' or Name startswith 'chat'
| extend p = parse_json(Properties)
| project TimeGenerated, Name,
    has_in  = isnotempty(tostring(p['gen_ai.input.messages'])),
    has_out = isnotempty(tostring(p['gen_ai.output.messages'])),
    nkeys   = array_length(bag_keys(p))
| order by TimeGenerated desc
| take 5
" -o table
```

Healthy redaction:
- `has_in` / `has_out` = **False** on all rows
- `nkeys` ≈ **12** (the allow-list count) instead of 19–22

You should also confirm the workspace is correctly linked:

```bash
az rest --method get --uri "https://management.azure.com$(az monitor log-analytics workspace show \
  -g $(azd env get-value AZURE_RESOURCE_GROUP) \
  -n $(azd env get-value LOG_ANALYTICS_WORKSPACE_NAME) --query id -o tsv)?api-version=2023-09-01" \
  --query "properties.defaultDataCollectionRuleResourceId" -o tsv
```

Expected output: the resource ID of `<env>-redact-genai-content`. **Empty
output means the link was never set** and the DCR is dormant regardless of
how long you wait.

### Demo: prove redaction to a stakeholder

Use this 5-minute script to show a stakeholder that redaction
actually works end-to-end. Best run with two terminals + the Foundry
portal open in a browser.

**Prereqs:** Bastion tunnel + SOCKS proxy up on the laptop (see
*"Query the trace data from the VM"* above for the tunnel setup). All
`az` calls below route through SOCKS — no SSH hop needed.

```bash
export HTTPS_PROXY=socks5h://127.0.0.1:1080

RG=$(azd env get-value AZURE_RESOURCE_GROUP)
WS_NAME=$(azd env get-value LOG_ANALYTICS_WORKSPACE_NAME)
WS_ID=$(az monitor log-analytics workspace show -g $RG -n $WS_NAME --query customerId -o tsv)

# Pick a cutoff timestamp: roughly when redaction activated on this
# workspace. Spans with TimeGenerated < CUTOFF show raw content; spans
# after show redacted content. Adjust if your env activated at a
# different time.
CUTOFF="2026-06-06T02:00:58Z"
```

#### Act 1 — "Here's the problem" (raw content in logs)

```bash
az monitor log-analytics query -w $WS_ID --analytics-query "
AppDependencies
| where TimeGenerated between (ago(8h) .. datetime($CUTOFF))
| where Name startswith 'invoke_agent'
| extend p = parse_json(Properties)
| project TimeGenerated,
          input  = tostring(p['gen_ai.input.messages']),
          output = tostring(p['gen_ai.output.messages'])
| top 1 by TimeGenerated desc
" -o json | python3 -m json.tool
```

→ Audience sees actual user prompt + model response sitting in the log.
**"Without redaction, anything the user typed lands here in clear text."**

#### Act 2 — "Here's the mechanism" (config inspection)

```bash
# Workspace-level activation knob
az monitor log-analytics workspace show -g $RG -n $WS_NAME \
  --query "properties.defaultDataCollectionRuleResourceId" -o tsv

# The DCR's transformation KQL
az monitor data-collection rule show -g $RG -n "${WS_NAME%-law}-redact-genai-content" \
  --query "properties.dataFlows[?contains(streams[0], 'AppDependencies')].transformKql" -o tsv
```

→ Two outputs: the linked DCR resource ID, and the `pack(...)` allow-list
KQL. **"One Bicep param, two resources. No SDK changes, no runtime
config. Ingestion-time enforcement on the workspace side."**

#### Act 3 — "Here's the proof, live"

Send a fresh prompt in DemoAgent **while they watch**. Wait ~90 seconds
for ingestion, then re-run the query against post-activation rows:

```bash
az monitor log-analytics query -w $WS_ID --analytics-query "
AppDependencies
| where TimeGenerated > datetime($CUTOFF)
| where Name startswith 'invoke_agent'
| extend p = parse_json(Properties)
| project TimeGenerated,
          input  = tostring(p['gen_ai.input.messages']),
          output = tostring(p['gen_ai.output.messages']),
          surviving_keys = bag_keys(p)
| top 1 by TimeGenerated desc
" -o json | python3 -m json.tool
```

→ `input` and `output` are blank. `surviving_keys` shows only safe
metadata (model, agent, IDs). **Place side-by-side with the Act 1 output
for the visual punchline.**

#### Act 4 — "But the trace is still useful" (portal walkthrough)

Switch to the Foundry portal: **Build → DemoAgent → Traces** → click
the run from Act 3.

Point out:
- ✅ Span tree (`invoke_agent` → `chat <model>`)
- ✅ Latency per span, total duration
- ✅ Token counts (input / output / cached)
- ✅ Status, agent ID, conversation ID
- ❌ **Input + Output panel: empty**

**"Full observability for debugging behavior, performance, and cost.
Zero conversation content stored."**

### Caveats

- **Records ingested before you enabled redaction are not affected.**
  Workspace transformations apply at ingestion only. To purge prior
  records, use [LAW table purge](https://learn.microsoft.com/azure/azure-monitor/logs/personal-data-mgmt)
  or wait for retention expiry (default 30 days in this stack).
- **The Foundry portal Trace detail view will show empty Input/Output
  panels.** This is the desired behavior, but be sure debugging workflows
  don't depend on seeing prompt text in the portal.
- **Transformation execution time counts toward ingestion latency.** The
  per-record KQL is cheap (microseconds) but the workspace transform DCR
  has a strict ≤20s budget; if you extend the KQL significantly, test it
  first.
- **One workspace transformation DCR per workspace.** If you already have
  one from another use case, merge the dataFlows rather than creating a
  second — `defaultDataCollectionRuleResourceId` accepts only one DCR ID.
- **Activation can take up to 60 minutes** after the workspace is linked
  to (or updated to point at) the DCR. Plan verification accordingly.
- **`dataCollectionRuleAssociations` resources do NOT activate workspace
  transformations.** That resource type is for VM/agent DCRs (e.g. Linux
  syslog) and is silently ignored here. We learned this the hard way —
  the docs only mention this in passing in the "Workspaces - Update API"
  step.

### Alternative postures (for completeness)

| Posture | How | When to use |
|---|---|---|
| Full content (default) | `redactPromptContent: false` | Internal debugging, demos, dev/test |
| Redacted content (this stack) | `redactPromptContent: true` | Production with PII concerns; teams wanting privacy + observability |
| No tracing at all | Delete the `<env>-ai-connection` project connection | Strictest posture; loses Tracing tab entirely |
| Client-side SDK only | Set `OTEL_INSTRUMENTATION_GENAI_CAPTURE_MESSAGE_CONTENT=false` on your own SDK code; don't use hosted prompt agents | When you control the runtime and use the Foundry SDK directly |

---

## Cost notes

App Insights and Log Analytics are pay-per-ingestion-GB. Agent traces are
small (a few KB per span × dozens of spans per run) — expect well under
the LAW free tier (5 GB/month) for normal demo use. For a quick estimate:

- 100 agent runs/day × ~40 KB of trace per run ≈ ~4 MB/day = ~120 MB/month
- AMPLS itself: **$0** (only the PE and DNS zones are billed; AMPLS is free)

If you want to cap costs at scale, set a daily ingestion cap on the LAW:

```bash
az monitor log-analytics workspace update \
  -g $(azd env get-value AZURE_RESOURCE_GROUP) \
  -n $(azd env get-value LOG_ANALYTICS_WORKSPACE_NAME) \
  --workspace-capping dailyQuotaGb=1
```

---

## How to wire this up for an existing project (no redeploy)

If you have an older deployment from before this Bicep change shipped and
don't want to redeploy, do the same thing the Bicep template does — create
the AppInsights project connection via REST:

```bash
SUB=$(az account show --query id -o tsv)
RG=$(azd env get-value AZURE_RESOURCE_GROUP)
FOUNDRY=$(azd env get-value FOUNDRY_NAME)
PROJ=$(echo "$(azd env get-value FOUNDRY_PROJECT_ENDPOINT)" | awk -F/ '{print $NF}')
AI_NAME=$(azd env get-value APPINSIGHTS_NAME)

AI_ID=$(az monitor app-insights component show -g $RG --app $AI_NAME --query id -o tsv)
AI_CONN=$(az monitor app-insights component show -g $RG --app $AI_NAME --query connectionString -o tsv)

az rest --method put \
  --url "https://management.azure.com/subscriptions/$SUB/resourceGroups/$RG/providers/Microsoft.CognitiveServices/accounts/$FOUNDRY/projects/$PROJ/connections/${AI_NAME}-connection?api-version=2025-04-01-preview" \
  --body "{
    \"properties\": {
      \"category\": \"AppInsights\",
      \"target\": \"$AI_ID\",
      \"authType\": \"ApiKey\",
      \"isSharedToAll\": true,
      \"credentials\": { \"key\": \"$AI_CONN\" },
      \"metadata\": { \"ApiType\": \"Azure\", \"ResourceId\": \"$AI_ID\" }
    }
  }"
```

Refresh the portal Tracing tab — the banner will disappear and your next
agent run will produce traces.

---

## Troubleshooting

**Tracing tab in portal is empty even after several agent runs.** This
is almost always caused by App Insights `publicNetworkAccessForIngestion`
being set to `Disabled` (the Foundry Agents runtime is Microsoft-managed
and cannot reach AMPLS-private ingestion endpoints). Verify:

```bash
az monitor app-insights component show \
  -g $(azd env get-value AZURE_RESOURCE_GROUP) \
  -n $(azd env get-value APPINSIGHTS_NAME) \
  --query publicNetworkAccessForIngestion -o tsv
```

If it returns `Disabled`, flip it (matching this stack's Bicep):

```bash
az monitor app-insights component update \
  -g $(azd env get-value AZURE_RESOURCE_GROUP) \
  -a $(azd env get-value APPINSIGHTS_NAME) \
  --ingestion-access Enabled
```

Send 2 more agent prompts and wait 60–90 seconds for ingestion.

**Tracing tab still shows the "Create or connect" banner.** The portal
caches the project connection list. Hard-refresh the page (`Cmd+Shift+R`
or `Ctrl+Shift+R`), or sign out and back in.

**`AppTraces` is empty but the portal shows traces.** Expected. Foundry
emits OTel client spans, which land in **`AppDependencies`**, not
`AppTraces`. Query `AppDependencies` (filter `AppRoleName == 'responsesapi'`
for managed-runtime rows).

**`AppRequests` Properties missing token counts.** The custom dimensions
populated depend on the Foundry runtime version. Some emit
`gen_ai.usage.input_tokens`, older versions emit
`promptTokens`/`completionTokens`. Check with `AppRequests | take 5 |
mv-expand Properties`.

**Bicep redeploy keeps re-applying the connection.** The
`appInsightsConnection` uses `credentials.key` which Bicep cannot read
back from a deployed resource, so every `azd up` re-applies it. Harmless
but noisy — the connection's behavior is unchanged across redeploys.
