# Connecting to the VM via Bastion & Accessing Foundry

A beginner-friendly walkthrough for reaching the test VM and using Foundry,
when everything is locked behind private endpoints.

> **Related guides**
> - [`README.md`](./README.md) — deploy this stack with `azd up`
> - [`Networking.md`](./Networking.md) — what's locked down and how
>   (every PE, every DNS zone, AMPLS scoped resources)
> - [`Foundry-Tracing.md`](./Foundry-Tracing.md) — once you're inside,
>   how Foundry agent traces flow into the private App Insights and how
>   to query them

## Why we need this

The Foundry account, project, and all backing services have
`publicNetworkAccess=Disabled`. They only answer requests that arrive over
their **private endpoints**, which only exist inside the VNet.

Your laptop can't talk to them directly — DNS resolves the endpoints to
their *public* IPs, and the services refuse the connection (you've already
seen the "Private network access required" message).

The fix is to **become a client inside the VNet**. The VM we deployed
(`<env>-vm`, on the workload subnet) is exactly such a client. We reach it
through **Azure Bastion**, a Microsoft-managed jump host that gives you a
browser-based SSH session into the VM without exposing port 22 to the
internet.

```
Your laptop  ──HTTPS──▶  Azure portal  ──Bastion──▶  VM  ──Private DNS──▶  Foundry PE
                                                       │
                                                       └──▶  Cosmos PE / Storage PE / Search PE / AMPLS PE
```

---

## Prerequisites

Before you start, you need:

1. **The Azure portal**: <https://portal.azure.com>
2. **The SSH key you used at deploy time**. We generated it at
   `~/.ssh/id_ed25519` (private) and `~/.ssh/id_ed25519.pub` (public).
   - If you don't remember whether you set one, run
     `azd env get-value SSH_PUBLIC_KEY` from the repo root — it will print
     the public key that was injected into the VM.
   - **Bastion's portal SSH session can use either** a password or a private
     key. Our VM only accepts the SSH key (no password), so you'll need the
     `id_ed25519` private key file uploaded into the Bastion dialog.
3. The values from `azd env get-values`. Useful ones (run these from the
   repo root on your laptop and copy the outputs into a scratch file —
   we'll paste them into commands below):

```bash
azd env get-value AZURE_RESOURCE_GROUP
azd env get-value VM_NAME
azd env get-value VM_ADMIN_USERNAME       # azureuser
azd env get-value BASTION_NAME
azd env get-value FOUNDRY_NAME
azd env get-value FOUNDRY_ENDPOINT
azd env get-value FOUNDRY_OPENAI_ENDPOINT
azd env get-value FOUNDRY_PROJECT_ENDPOINT
azd env get-value FOUNDRY_MODEL_DEPLOYMENT_NAME
```

---

## Path 1 — In-browser SSH (works today, Basic Bastion)

This is the simplest path and uses what we already deployed. You get a
terminal in the Azure portal, no extra setup, no cost increase. You won't be
able to open the Foundry portal in a local browser this way, but you *can*
do every kind of Foundry interaction through the Azure CLI and `curl`.

### Step 1: Open the VM in the Azure portal

1. Sign in to <https://portal.azure.com>.
2. In the top search bar, type your VM name (from
   `azd env get-value VM_NAME`) and click it under **Resources**.
3. On the VM's left-hand menu, click **Connect** → **Connect via Bastion**.
   (Older portal versions: there's a tab labelled "Bastion" inside the
   Connect page.)

### Step 2: Fill in the Bastion dialog

| Field | What to put |
|---|---|
| **Authentication type** | `SSH Private Key from Local File` |
| **Username** | `azureuser` |
| **Local file** | Click "Browse" and pick `~/.ssh/id_ed25519` (the **private** key, no `.pub`) |
| **SSH passphrase** | Leave blank (the key we generated has no passphrase) |
| **Open in new browser tab** | ✅ recommended (so you can keep the portal open separately) |

Click **Connect**.

A new tab opens with a black terminal. The first time, your browser may
prompt for clipboard permission — click *Allow*. You're now SSH'd into the
VM with a shell prompt like:

```
azureuser@<vm-name>:~$
```

### Step 3: Confirm the VM can see Foundry privately

Grab the hostnames from your azd outputs first (run on your laptop, copy the
host part — everything between `https://` and the next `/`):

```bash
azd env get-value FOUNDRY_ENDPOINT          # https://<account-host>/
azd env get-value FOUNDRY_PROJECT_ENDPOINT  # https://<account-host>/api/projects/<proj>
```

Then on the VM:

```bash
# Replace <account-host> with the host you copied above.
# These should resolve to a 10.20.2.x address (the PE), NOT a public IP.
getent hosts <account-host>                                  # cognitiveservices.azure.com
getent hosts $(echo <account-host> | sed 's/cognitiveservices/openai/')
getent hosts $(echo <account-host> | sed 's/cognitiveservices.azure.com/services.ai.azure.com/')
```

You should see something like:
```
10.20.2.4    <account-host>
```

If you see a public IP (e.g. starts with 20., 52., 13., 168.), the private
DNS link isn't working — open an issue.

### Step 4: Log in to Azure from the VM, then call Foundry

The VM has the Azure CLI pre-installed. Log in once using your own account:

```bash
az login --use-device-code
```

Copy the device code shown, follow the URL it prints (you can do this from
your laptop browser), sign in, and the CLI on the VM will receive your
token.

Set the subscription (the VM is in the same one your azd env points at):
```bash
az account set --subscription "$(az account show --query id -o tsv)"
# Or if you have multiple tenants/subs, look it up explicitly:
#   az account list -o table   # then: az account set --subscription <SUB_ID>
```

Now you can talk to Foundry. Pull the names from azd outputs you noted in
the Prerequisites section, or run `azd env get-values` on your laptop:

```bash
FOUNDRY_NAME="<your foundry account name>"           # e.g. azd env get-value FOUNDRY_NAME
RG="<your resource group>"                            # e.g. azd env get-value AZURE_RESOURCE_GROUP
FOUNDRY_OAI="<openai endpoint>"                       # e.g. azd env get-value FOUNDRY_OPENAI_ENDPOINT (ends with /)
MODEL_DEPLOY="<your model deployment name>"           # e.g. azd env get-value FOUNDRY_MODEL_DEPLOYMENT_NAME

# List your model deployments
az cognitiveservices account deployment list \
  -n "$FOUNDRY_NAME" -g "$RG" \
  -o table

# Get an AAD token for the Cognitive Services data plane
TOKEN=$(az account get-access-token \
  --resource https://cognitiveservices.azure.com \
  --query accessToken -o tsv)

# Hit the openai-format endpoint with your model deployment
curl -sS "${FOUNDRY_OAI}openai/deployments/${MODEL_DEPLOY}/chat/completions?api-version=2024-10-21" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "messages": [{"role":"user","content":"Say hi in 5 words."}],
    "max_tokens": 50
  }' | jq -r '.choices[0].message.content'
```

You should get back a short greeting. **That round trip went**:
laptop → Bastion → VM → private endpoint in 10.20.2.0/24 → Foundry account.
The model itself runs in Azure's managed network; the call from your VM is
the only segment that ever touched the VNet.

### Step 5 (optional): Use the Foundry SDK from Python on the VM

The VM is a stock Ubuntu image; install Python tooling once:
```bash
sudo apt update && sudo apt install -y python3-venv
python3 -m venv ~/foundry-venv
source ~/foundry-venv/bin/activate
pip install azure-ai-projects azure-identity openai
```

Then a quick smoke test (substitute your project endpoint, available from
`azd env get-value FOUNDRY_PROJECT_ENDPOINT` on your laptop):

```bash
PROJECT_ENDPOINT="<paste your FOUNDRY_PROJECT_ENDPOINT here>"

python3 - <<EOF
from azure.ai.projects import AIProjectClient
from azure.identity import DefaultAzureCredential
endpoint = "$PROJECT_ENDPOINT"
client = AIProjectClient(endpoint=endpoint, credential=DefaultAzureCredential())
print("Connections in project:")
for c in client.connections.list():
    print(f"  - {c.name}  type={c.type}")
EOF
```

You should see your three project connections listed (Cosmos / Storage /
Search).

### Step 6: Disconnect cleanly

Just close the Bastion browser tab. The VM keeps running. Bastion itself
keeps charging by the hour whether you're connected or not — see the
*Costs* section in `README.md`.

---

## Path 2 — Browse the Foundry portal in your laptop browser (needs Standard Bastion)

The Foundry Portal (<https://ai.azure.com>) is a web UI that talks to your
Foundry **data plane** the same way SDKs do. Because the data plane only
answers private endpoints, your laptop's browser can't reach it directly.

The fix is to **forward your laptop browser's traffic through the VM**
inside the VNet, using SSH dynamic port-forwarding (SOCKS5 proxy). That
requires Bastion to support **native client tunneling**, which is a
Standard/Premium SKU feature. Our deployment uses Basic.

### Step A: Upgrade Bastion to Standard

This is a property change on the existing Bastion resource (no recreate
required), and adds about **$0.12/hour** on top of Basic's ~$0.19/hour.

```bash
# From the repo root, with your azd env selected
az network bastion update \
  --name "$(azd env get-value BASTION_NAME)" \
  --resource-group "$(azd env get-value AZURE_RESOURCE_GROUP)" \
  --sku '{"name":"Standard"}' \
  --enable-tunneling true
```

> **Why `--sku` looks weird:** the `bastion` CLI extension currently expects `--sku` as a JSON object (`{"name":"Standard"}`), not a flat string. Passing `--sku Standard` fails with `dict type value expected, got 'Standard'`.

The update takes about 5 minutes. Confirm:
```bash
az network bastion show -n "$(azd env get-value BASTION_NAME)" -g "$(azd env get-value AZURE_RESOURCE_GROUP)" \
  --query "{sku:sku.name, tunneling:enableTunneling}" -o table
```
You want `Standard` and `true`.

If you want to make the change persistent in Bicep, edit
`infra/modules/bastion.bicep` and add `sku: { name: 'Standard' }` plus
`enableTunneling: true` on the `properties` object.

### Step B: Install the Azure CLI Bastion extension (one-time, on your laptop)

```bash
az extension add --name bastion --upgrade
```

### Step C: Open a TCP tunnel from your laptop → VM port 22

In one terminal on your laptop:

```bash
RG=$(azd env get-value AZURE_RESOURCE_GROUP)
BASTION=$(azd env get-value BASTION_NAME)
VM_ID=$(az vm show -g "$RG" -n "$(azd env get-value VM_NAME)" --query id -o tsv)

az network bastion tunnel \
  --name "$BASTION" \
  --resource-group "$RG" \
  --target-resource-id "$VM_ID" \
  --resource-port 22 \
  --port 50022
```

Leave this running. It prints
`Opening tunnel on port: 50022 ... Tunnel is ready, connect on port 50022`.

### Step D: SSH from your laptop through the tunnel + open a SOCKS5 proxy

In a **second** terminal on your laptop:

```bash
ssh -i ~/.ssh/id_ed25519 \
    -D 1080 \
    -N \
    -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null \
    -p 50022 \
    azureuser@127.0.0.1
```

The flags:
- `-p 50022` → connect through the Bastion tunnel from Step C
- `-D 1080` → open a **SOCKS5 proxy** on your laptop's `localhost:1080`,
  which forwards browser traffic through the SSH session into the VM
- `-N` → don't open a shell (just maintain the tunnel)
- `StrictHostKeyChecking=no` → suppress the host-key prompt (the VM is
  ephemeral)

Leave this running too. You won't get a prompt; if it returned
immediately, ssh failed and you can re-run without `-N` to see the error.

### Step E: Point your browser at the SOCKS proxy

You need the browser to send **both** its HTTP traffic and its DNS lookups
through the SOCKS5 proxy at `127.0.0.1:1080`. If DNS leaks (your laptop
resolves the hostname locally), you'll keep hitting the public IP and the
service will refuse you.

Pick the section that matches your browser.

#### Option 1: Edge (or Chrome) + FoxyProxy extension — recommended

[FoxyProxy](https://getfoxyproxy.org/) is a free extension that adds a
per-site proxy switcher. It handles DNS-over-SOCKS correctly when you
configure it for SOCKS5.

1. **Install the extension.** In Edge, open
   <https://microsoftedge.microsoft.com/addons/search/foxyproxy> (or in
   Chrome, the Chrome Web Store), search for **FoxyProxy Standard**, and
   click *Get* → *Add extension*.
2. **Pin it.** Click the *Extensions* puzzle-piece in the toolbar and pin
   FoxyProxy so its icon stays visible.
3. **Open FoxyProxy options.** Click the FoxyProxy icon → *Options*.
4. **Add a new proxy.** Click *Add* (or *Proxies* → *Add*) and fill in:

   | Field | Value |
   |---|---|
   | Title | `Foundry VNet (SOCKS5)` |
   | Proxy type | `SOCKS5` |
   | Hostname / IP | `127.0.0.1` |
   | Port | `1080` |
   | Username / Password | *(leave blank)* |
   | **Send DNS through SOCKS5 proxy** | ✅ **check this** — critical |

   Click *Save*.
5. **Activate it from the toolbar (not the Options page).** Click the
   **FoxyProxy icon** in the Edge/Chrome toolbar (top-right; pin it via the
   *Extensions* puzzle-piece if you can't see it). A small popup lists your
   proxies — click **`Foundry VNet (SOCKS5)`** to start routing *all*
   traffic through the VM. The icon badge changes color when active.

   > The on/off slider on the proxy *card* in Options only marks the entry
   > as *eligible*. It does **not** activate it — selection happens from the
   > toolbar popup.

   If you want per-site routing instead of all traffic, expand the
   *Proxy by Patterns* row on the proxy card in Options, add wildcard
   patterns for `*://*.azure.com/*`, `*://*.microsoftonline.com/*`,
   `*://*.msauth.net/*`, `*://*.msftauth.net/*`, save, then in the toolbar
   popup pick *Use Enabled Proxies By Patterns and Order*.
6. **Verify before logging in.** Browse to <https://api.ipify.org>. With
   "all URLs" mode on, it should show your VM's egress public IP (different
   from your laptop's). If it shows your laptop's IP, the proxy is not
   active — re-check FoxyProxy's mode and that the SSH session in Step D is
   still alive.
7. **Browse Foundry.** Go to <https://ai.azure.com>. The page should load
   normally and let you sign in.

> **Edge profile tip:** if you want a clean session that doesn't disturb
> your normal browsing, open Edge → click your profile avatar → *Add
> profile*, install FoxyProxy in just that profile, and use it for
> Foundry-only work.

#### Option 2: Firefox (built-in, no extension required)

1. Open `about:preferences#general`, scroll to the bottom, click
   **Settings…** next to *Network Settings*.
2. Choose **Manual proxy configuration**.
3. **SOCKS Host**: `127.0.0.1`  **Port**: `1080`. Select **SOCKS v5**.
4. ✅ Check **Proxy DNS when using SOCKS v5** (critical — this makes
   `*.cognitiveservices.azure.com` resolve via the VM's DNS, which sees
   the private endpoint).
5. Click **OK** and browse to <https://ai.azure.com>.

#### Option 3: Chrome / Edge launched directly with flags

Skip FoxyProxy by launching a separate browser instance with command-line
flags. Useful for one-off testing:

```bash
# macOS — Edge
/Applications/Microsoft\ Edge.app/Contents/MacOS/Microsoft\ Edge \
  --user-data-dir=/tmp/edge-foundry \
  --proxy-server="socks5://127.0.0.1:1080" \
  --host-resolver-rules="MAP * ~NOTFOUND , EXCLUDE 127.0.0.1" \
  https://ai.azure.com

# macOS — Chrome
/Applications/Google\ Chrome.app/Contents/MacOS/Google\ Chrome \
  --user-data-dir=/tmp/chrome-foundry \
  --proxy-server="socks5://127.0.0.1:1080" \
  --host-resolver-rules="MAP * ~NOTFOUND , EXCLUDE 127.0.0.1" \
  https://ai.azure.com
```

The `--host-resolver-rules` flag is what forces DNS through the proxy.
Without it, Edge/Chrome will leak DNS lookups even with `--proxy-server`
set.

### Step F: Open Foundry

Browse to <https://ai.azure.com>. Sign in with your Azure account, then
select your project (`<env>-proj` in `<env>-aif`, in your subscription /
resource group).

You should now have the full Foundry Portal experience — Playground,
Connections, Models, Deployments, etc. — even though Foundry is locked to
private endpoints, because your browser traffic is now arriving from inside
the VNet.

### Step G: Shut it down

To stop the tunnel: `Ctrl+C` the SSH session, then `Ctrl+C` the
`az network bastion tunnel` session. Then disable your browser proxy:

- **FoxyProxy:** click the toolbar icon → *Turn Off* / *Disable
  FoxyProxy*.
- **Firefox built-in:** *Settings* → *Network Settings* → *No proxy*.
- **Chrome/Edge launched with flags:** just close the dedicated browser
  window — your normal Edge/Chrome instances were never affected.

**Stop the VM to avoid compute charges** (it costs ~$0.05/hour while
running, $0 while deallocated):
```bash
az vm deallocate -g "$(azd env get-value AZURE_RESOURCE_GROUP)" \
  -n "$(azd env get-value VM_NAME)" --no-wait
```
Bastion itself keeps billing whether the VM is running or not — see the
Cost notes section.

---

## Cost notes

| Resource | Approx. cost (East US-2 list) |
|---|---|
| Bastion **Basic** | ~$0.19/hour (~$140/month) |
| Bastion **Standard** | ~$0.31/hour (~$226/month) |
| Bastion outbound data | First 5 GB/month free, then ~$0.087/GB |
| Test VM (Standard_B2ms) | ~$0.05/hour (~$36/month) |

Bastion bills by the hour whether you're connected or not. If you only
need it for occasional troubleshooting, consider downgrading back to Basic
or deleting Bastion entirely between sessions and recreating with Bicep.
For a multi-day demo / workshop, leave it up.

---

## Troubleshooting

**Bastion connect button greyed out.** The portal sometimes hides Bastion
options until you wait ~30s after the page loads. Refresh and try again.

**`Permission denied (publickey)` in the Bastion dialog.** The private key
you uploaded doesn't match the public key on the VM. Confirm with:
```bash
diff <(ssh-keygen -y -f ~/.ssh/id_ed25519) <(azd env get-value SSH_PUBLIC_KEY | sed 's/ foundry-networking$//')
```
The first column should be empty (no differences).

**`getent hosts` returns a public IP.** Private DNS zones aren't linked to
the VNet, or your VM was created before the link existed. Re-run
`azd provision` to reconcile.

**`Bastion tunneling: false` after the update command.** Double-check the
SKU is `Standard`. Tunneling is silently ignored on Basic.

**`Connection timed out during banner exchange` from ssh.** Bastion accepted
your TCP on port 50022 but couldn't reach the VM's port 22. Almost always
means the VM is **deallocated** (stopped). Check and start it:
```bash
az vm get-instance-view -g "$(azd env get-value AZURE_RESOURCE_GROUP)" \
  -n "$(azd env get-value VM_NAME)" \
  --query 'instanceView.statuses[?starts_with(code, `PowerState/`)].displayStatus' -o tsv
az vm start -g "$(azd env get-value AZURE_RESOURCE_GROUP)" -n "$(azd env get-value VM_NAME)"
```
Then **kill and restart** the `az network bastion tunnel` process — it
caches the failed route and won't recover on its own.

**Edge/Chrome shows `ERR_PROXY_CONNECTION_FAILED` even though `curl
--socks5-hostname` works.** The browser cached the proxy failure from a
moment when the SSH SOCKS listener was down (e.g. the SSH process exited).
Fix:
1. Confirm the listener is alive again: `lsof -iTCP:1080 -sTCP:LISTEN` —
   you should see an `ssh` process.
2. In Edge/Chrome, **hard-refresh** the tab (`Cmd+Shift+R` / `Ctrl+Shift+R`),
   or close and re-open it in a new InPrivate window.
3. As a sanity check before retrying the Foundry tab, browse to
   <https://api.ipify.org> — it should show your *VM's* egress public IP,
   not your laptop's home IP.

**Both tunnels die after laptop sleeps or you switch networks.** The
`az network bastion tunnel` (port 50022) and `ssh -D 1080 -N` (SOCKS5)
sessions don't auto-reconnect when your laptop wakes up or your Wi-Fi
flips. Just re-run them — Step C, then Step D. Bastion itself stays up;
only the laptop side of the tunnel breaks.

**The SSH tunnel keeps closing** ("Connection reset by peer"). The Bastion
tunnel idle-times out at ~3-4 hours. Re-run the
`az network bastion tunnel` command and reconnect.

**Browser shows "Private network access required" even with the proxy.**
DNS is leaking — the browser resolved the hostname locally to its public IP
instead of asking the VM. Checks:
- **FoxyProxy:** open the proxy's settings and confirm *Send DNS through
  SOCKS5 proxy* is ticked. Also confirm the toolbar icon is *on* (not grey)
  and pointing at your SOCKS5 entry, not "Disabled".
- **Firefox built-in:** confirm *Proxy DNS when using SOCKS v5* is ticked.
- **Chrome/Edge with flags:** confirm you passed
  `--host-resolver-rules="MAP * ~NOTFOUND , EXCLUDE 127.0.0.1"`. Without
  it the browser bypasses SOCKS for DNS.
- Sanity check: visit <https://api.ipify.org> — it should show the VM's
  egress IP, not your laptop's.

**`az` from inside the VM says you have no access.** You logged in as
yourself, but your account doesn't have data-plane RBAC on the Foundry
account. Either: (a) grant your own user the `Cognitive Services OpenAI
User` role on the account, or (b) use the VM's managed identity instead by
running `az login --identity` — that identity already has the role
assigned.

---

## TL;DR commands

```bash
# Path 1 — quick verification via portal Bastion (no upgrade needed)
# 1. Portal → VM → Connect via Bastion → upload ~/.ssh/id_ed25519
# 2. From the VM shell:
az login --use-device-code
TOKEN=$(az account get-access-token --resource https://cognitiveservices.azure.com --query accessToken -o tsv)
curl -sS "$(azd env get-value FOUNDRY_OPENAI_ENDPOINT)openai/deployments/$(azd env get-value FOUNDRY_MODEL_DEPLOYMENT_NAME)/chat/completions?api-version=2024-10-21" \
  -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  -d '{"messages":[{"role":"user","content":"hi"}],"max_tokens":20}'

# Path 2 — browse the Foundry portal locally (one-time upgrade)
az network bastion update -n "$(azd env get-value BASTION_NAME)" -g "$(azd env get-value AZURE_RESOURCE_GROUP)" --sku '{"name":"Standard"}' --enable-tunneling true

# Terminal 1:
VM_ID=$(az vm show -g "$(azd env get-value AZURE_RESOURCE_GROUP)" -n "$(azd env get-value VM_NAME)" --query id -o tsv)
az network bastion tunnel -n "$(azd env get-value BASTION_NAME)" -g "$(azd env get-value AZURE_RESOURCE_GROUP)" --target-resource-id "$VM_ID" --resource-port 22 --port 50022

# Terminal 2:
ssh -i ~/.ssh/id_ed25519 -D 1080 -N -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -p 50022 azureuser@127.0.0.1

# Then in your browser, route traffic through 127.0.0.1:1080 via SOCKS5:
#   - Edge/Chrome: FoxyProxy extension, SOCKS5 127.0.0.1:1080, "Send DNS through SOCKS5" ON
#   - Firefox:     Network Settings → SOCKS5 127.0.0.1:1080, "Proxy DNS when using SOCKS v5" ON
# Browse https://ai.azure.com
```
