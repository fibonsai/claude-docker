# claude-docker

A minimal Alpine-based Docker image that runs **[Claude Code](https://claude.ai/code)** (the official Anthropic CLI) inside a container.

Built on [`fibonsai/omniroute-docker`](https://github.com/fibonsai/omniroute-docker) patterns, this image is designed to run Claude Code through **[OmniRoute](https://github.com/diegosouzapw/OmniRoute)** — a unified AI gateway exposing hundreds of providers behind a single OpenAI-compatible endpoint — with **NVIDIA OpenShell** as the sandboxed execution environment.

> OmniRoute (referred to as "omnirouter" throughout this README) is the OpenAI-compatible gateway that sits between your sandboxed agent and the upstream model providers. It is maintained upstream by Diego Souza and packaged in `fibonsai/omniroute-docker`.

---

## What this image does

- Installs Claude Code CLI (`~claude/.local/bin/claude`) on Alpine
- Runs as the unprivileged `claude` user
- Works standalone (`claude` directly) or routed through OmniRoute via OpenShell sandboxes

The Dockerfile in this repo:

```dockerfile
FROM alpine:latest

RUN adduser claude || true
RUN echo "https://dl-cdn.alpinelinux.org/alpine/v3.22/community" >> /etc/apk/repositories && apk update
RUN apk add --no-cache ca-certificates curl libc6-compat tzdata bash libgcc libstdc++ ripgrep

USER claude
RUN curl -fsSL https://claude.ai/install.sh | bash 
ENV PATH=${PATH}:~claude/.local/bin

WORKDIR /workspace
```

---

## Quick start (standalone)

Build and run Claude Code directly, without OmniRoute:

```bash
# 1. Build the image
docker build -t claude-docker .

# 2. Run Claude Code
docker run -it --rm \
  --name claude-code \
  -e ANTHROPIC_API_KEY="${ANTHROPIC_API_KEY}" \
  -v "$PWD:/workspace" \
  -w /workspace \
  claude-docker \
  claude
```

Claude Code authenticates directly to Anthropic with `ANTHROPIC_API_KEY`.

---

## Running through OmniRoute + NVIDIA OpenShell (recommended)

The secure, multi-provider architecture routes every sandboxed agent through **OmniRoute**, which holds the real upstream provider keys (`NVIDIA_API_KEY`, `OPENROUTER_API_KEY`, `GEMINI_API_KEY`, etc.) in its own system environment. The sandbox agent sees **only** an OmniRoute API key (`OMNIROUTE_API_KEY`) and can reach **only** OmniRoute's OpenAI-compatible endpoint — never the upstream providers directly.

```
OpenCode / Claude Code / curl (sandbox)
        │  OMNIROUTE_API_KEY (opaque placeholder)
        ▼
OmniRoute :20128/v1   (OpenAI-compatible gateway)
        │  real provider keys (stay outside the sandbox)
        ▼
NVIDIA NIM, OpenAI, Anthropic, Gemini, OpenRouter, ...
```

This repo follows the provider profile patterns from [`fibonsai/omniroute-docker`](https://github.com/fibonsai/omniroute-docker/tree/main/openshell).

### Prerequisites

- Docker (or Podman)
- [NVIDIA OpenShell](https://docs.nvidia.com/openshell/) installed (`openshell` CLI)
- An OmniRoute image built from `fibonsai/omniroute-docker`
- Provider API keys declared in OmniRoute's environment at startup

### Step 1 — Start OmniRoute

Publish the API port so sandboxes can reach it, and require an OmniRoute API key:

```bash
docker run -d \
  --name omniroute \
  --restart unless-stopped \
  -p 20128:20128 \
  -e INITIAL_PASSWORD='change-this-password' \
  -e REQUIRE_API_KEY='true' \
  -e NVIDIA_API_KEY="${NVIDIA_API_KEY}" \
  -e OPENROUTER_API_KEY="${OPENROUTER_API_KEY}" \
  -e GEMINI_API_KEY="${GEMINI_API_KEY}" \
  -v omniroute-data:/home/node/.omniroute \
  fibonsai/omniroute-docker
```

Open [http://localhost:20128](http://localhost:20128), log in with `INITIAL_PASSWORD`, and create an API key under **Endpoints**. Export it for OpenShell:

```bash
export OMNIROUTE_API_KEY='omni-...'
```

Destination provider keys must be present in OmniRoute's system environment **before** the container starts (they are read at startup, not added afterward through the dashboard).

### Step 2 — Create the OpenShell provider profile

Use the profile below. The endpoint host must be the address the sandbox uses to reach OmniRoute. `host.openshell.internal` is the documented host gateway for a service running on the OpenShell host; if OmniRoute runs elsewhere (or on another container network), replace `host.openshell.internal` with that reachable hostname or IP.

Save as `openshell/omniroute.yaml`:

```yaml
id: omniroute
display_name: OmniRoute
description: Self-hosted OmniRoute OpenAI-compatible gateway with system-env provider keys
category: inference
inference_capable: true

credentials:
  - name: api_key
    description: OmniRoute API key (sandbox-facing, opaque placeholder)
    env_vars: [OMNIROUTE_API_KEY]
    required: true
    auth_style: bearer
    header_name: authorization

discovery:
  credentials: [api_key]

endpoints:
  - host: host.openshell.internal
    port: 20128
    path: /v1/**
    protocol: rest
    access: read-write
    enforcement: enforce

binaries:
  - /usr/local/bin/opencode
  - /usr/local/bin/node
  - /usr/bin/curl
  - /usr/local/bin/curl
```

The profile enforces strict credential-to-endpoint binding:

- **Sandbox sees only `OMNIROUTE_API_KEY`.** Upstream `{PROVIDER}_API_KEY` values never enter the sandbox.
- **`path: /v1/**`** limits the sandbox to OmniRoute's OpenAI-compatible API; the dashboard and every other host are unreachable.
- **`enforcement: enforce`** blocks any request outside the allowed endpoint.
- **`binaries` allowlist** restricts which processes may use the endpoint.

Lint, import, and create the provider:

```bash
openshell profile lint -f openshell/omniroute.yaml
openshell profile import -f openshell/omniroute.yaml
openshell provider create --name omniroute --type omniroute --from-existing
```

`--from-existing` reads `OMNIROUTE_API_KEY` from your shell and stores it in OpenShell; the sandbox receives only an opaque placeholder.

### Step 3 — Run OpenCode through OmniRoute

Save this OpenCode config as `opencode.json`:

```json
{
  "$schema": "https://opencode.ai/config.json",
  "providers": {
    "omniroute": {
      "name": "OmniRoute",
      "env": ["OMNIROUTE_API_KEY"],
      "package": "@opencode/ai/providers/openai-compatible",
      "settings": {
        "baseURL": "http://host.openshell.internal:20128/v1"
      },
      "models": {
        "auto": { "name": "OmniRoute auto" }
      }
    }
  }
}
```

Create a detached sandbox from the OpenCode image, upload the config, and start the agent:

```bash
openshell sandbox create \
  --name omniroute-agent \
  --from ghcr.io/anomalyco/opencode:latest \
  --provider omniroute \
  --upload ./opencode.json:/workspace/opencode.json \
  --no-git-ignore \
  --detach

openshell sandbox exec -n omniroute-agent --workdir /workspace -- \
  opencode run --model omniroute/auto "Summarize the files in this workspace."
```

OpenCode reads `OMNIROUTE_API_KEY` from the sandbox environment, sends it to `host.openshell.internal:20128/v1`, and OmniRoute chooses a provider for the `auto` model.

If the detached login shell exits immediately, use a keepalive instead:

```bash
openshell sandbox create \
  --name omniroute-agent \
  --from ghcr.io/anomalyco/opencode:latest \
  --provider omniroute \
  --detach \
  -- sh -c 'sleep 86400'

openshell sandbox upload omniroute-agent ./opencode.json /workspace/opencode.json --no-git-ignore

openshell sandbox exec -n omniroute-agent --workdir /workspace -- \
  opencode run --model omniroute/auto "Summarize the files in this workspace."
```

For an interactive session in OpenCode 2.x, use `opencode mini --model omniroute/auto`.

To pin a destination provider, use a model ID that OmniRoute exposes (e.g. `omniroute/nvidia/<model-id>`), listed by `opencode models` or the OmniRoute dashboard.

### Step 4 — Run Claude Code through OmniRoute

Claude Code can point at any OpenAI-compatible endpoint via `ANTHROPIC_BASE_URL` and `ANTHROPIC_AUTH_TOKEN`. Build your own image with the Claude Code CLI installed (this repo's Dockerfile) and reference it as `<your-claude-code-image>`. Run it inside an `omniroute` sandbox so it reaches OmniRoute — and therefore every connected provider — without holding any upstream `{PROVIDER}_API_KEY`:

```bash
openshell sandbox create \
  --name claude-code-agent \
  --from <your-claude-code-image> \
  --provider omniroute \
  --env OMNIROUTE_API_KEY="${OMNIROUTE_API_KEY}" \
  --env ANTHROPIC_BASE_URL=http://host.openshell.internal:20128/v1 \
  --env ANTHROPIC_AUTH_TOKEN="${OMNIROUTE_API_KEY}" \
  --detach \
  -- sh -c 'sleep 86400'

openshell sandbox exec -n claude-code-agent --workdir /workspace -- \
  claude "Summarize the files in this workspace."
```

Claude Code authenticates to OmniRoute with `OMNIROUTE_API_KEY`, and OmniRoute routes to the configured provider (e.g. NVIDIA NIM, OpenAI, Gemini). The Claude Code sandbox never sees `NVIDIA_API_KEY`, `GEMINI_API_KEY`, or any other upstream key.

### Step 5 — Run Hermes Gateway through OmniRoute

Hermes Agent (NousResearch) runs inside an OpenShell sandbox via the OpenShell gateway (`hermesclaw`, from the `hermesclaw` project — there is no official NousResearch/NVIDIA Docker image; build your own image with `hermesclaw` installed). Point Hermes Gateway at OmniRoute's OpenAI-compatible endpoint so all model traffic is proxied through OmniRoute:

```bash
openshell sandbox create \
  --name hermes-agent \
  --from <your-hermes-image> \
  --provider omniroute \
  --env OMNIROUTE_API_KEY="${OMNIROUTE_API_KEY}" \
  --env HERMES_GATEWAY_URL=http://host.openshell.internal:20128/v1 \
  --env HERMES_API_KEY="${OMNIROUTE_API_KEY}" \
  --detach \
  -- sh -c 'sleep 86400'

openshell sandbox exec -n hermes-agent --workdir /workspace -- \
  hermesclaw chat "Summarize the files in this workspace."
```

The Hermes sandbox holds only `OMNIROUTE_API_KEY`. Hermes Gateway sends requests to OmniRoute, which forwards to the destination provider using the `{PROVIDER}_API_KEY` kept in OmniRoute's system environment — never exposed to the Hermes sandbox.

---

## Two-sandbox architecture with two exclusive OpenShell providers

Use two dedicated OpenShell providers, one per sandbox:

| Sandbox | Provider | Purpose |
| --- | --- | --- |
| OmniRoute sandbox | `omniroute-all-providers` | Runs `omniroute --daemon` inside the sandbox. Holds all `{PROVIDER}_API_KEY` values and proxies agent requests to the correct provider endpoint. |
| Agent sandbox (OpenCode, Claude Code, curl) | `omniroute-agent` | Runs the agent. Holds only `OMNIROUTE_API_KEY`. Can reach **only** the OmniRoute gateway endpoint; no provider keys and no direct provider-endpoint access. |

This keeps the agent sandbox free of all provider keys and prevents any credential from being used against the wrong endpoint.

### 1. OmniRoute sandbox — `omniroute-all-providers` provider

This sandbox runs the OmniRoute daemon. It binds every `{PROVIDER}_API_KEY` to its respective provider endpoint so each key is used only for its intended provider:

```bash
openshell profile lint -f openshell/omniroute-all-providers.yaml
openshell profile import -f openshell/omniroute-all-providers.yaml
openshell provider create --name omniroute-all-providers --type omniroute-all-providers --from-existing
```

```bash
openshell sandbox create \
  --name omniroute \
  --from local/omniroute \
  --provider omniroute-all-providers \
  -- omniroute --daemon
```

The `omniroute-all-providers` profile enforces:

- **OmniRoute gateway endpoint** (`host.openshell.internal:20128/v1`) reachable via `OMNIROUTE_API_KEY`.
- **Each `{PROVIDER}_API_KEY` bound to its own endpoint.** `OPENROUTER_API_KEY` only reaches `openrouter.ai`, `NVIDIA_API_KEY` only NVIDIA endpoints, etc. (`enforcement: enforce`). OmniRoute, as the trusted proxy daemon in this sandbox, holds these keys and routes each request to the correct provider.
- **`binaries` allowlist** restricts this sandbox to the `omniroute` proxy binary and `node`.

### 2. Agent sandbox — `omniroute-agent` provider

This sandbox runs the agent (OpenCode, Claude Code, curl). It holds **only** `OMNIROUTE_API_KEY` and can reach **only** the OmniRoute gateway endpoint. No provider keys enter this sandbox, and the agent cannot call any provider endpoint directly:

```bash
openshell profile lint -f openshell/omniroute-agent.yaml
openshell profile import -f openshell/omniroute-agent.yaml
openshell provider create --name omniroute-agent --type omniroute-agent --from-existing
```

```bash
openshell sandbox create \
  --name omniroute-agent \
  --from ghcr.io/anomalyco/opencode:latest \
  --provider omniroute-agent \
  --env OMNIROUTE_API_KEY="${OMNIROUTE_API_KEY}" \
  --env OPENAI_BASE_URL=http://host.openshell.internal:20128/v1 \
  --detach \
  -- sh -c 'sleep 86400'
```

The `omniroute-agent` profile enforces:

- **Sandbox agent sees only `OMNIROUTE_API_KEY`.** Upstream `{PROVIDER}_API_KEY` values never enter this sandbox.
- **`path: /v1/**`** limits the agent to OmniRoute's OpenAI-compatible API; every other host (including all provider endpoints) is unreachable from the agent.
- **`enforcement: enforce`** blocks any request outside the allowed endpoint.
- **`binaries` allowlist** restricts agent binaries (`opencode`, `node`, `curl`) to the OmniRoute gateway endpoint.

Each provider is exclusive to its sandbox; never share a provider between the OmniRoute sandbox and the agent sandbox.

Profile files live in `openshell/`:

- `openshell/omniroute.yaml` — single-provider profile (used above in Steps 1–5).
- `openshell/omniroute-all-providers.yaml` — for the OmniRoute daemon sandbox.
- `openshell/omniroute-agent.yaml` — for the agent sandbox.

---

## Docker Compose example

Run OmniRoute (the gateway) with Docker Compose, then connect sandboxed agents to it.

```yaml
services:
  omniroute:
    build:
      context: https://github.com/fibonsai/omniroute-docker.git
      args:
        OMNIROUTE_VERSION: latest
        INSTALL_OPTIONAL_DEPS: "false"
        REMOVE_TRANSLATED_DOCS: "true"
    image: fibonsai/omniroute-docker
    container_name: omniroute
    restart: unless-stopped
    ports:
      - "20128:20128"
      - "20129:20129"
    environment:
      INITIAL_PASSWORD: change-this-password
      REQUIRE_API_KEY: "true"
      NVIDIA_API_KEY: ${NVIDIA_API_KEY}
      OPENROUTER_API_KEY: ${OPENROUTER_API_KEY}
      GEMINI_API_KEY: ${GEMINI_API_KEY}
      TZ: America/Sao_Paulo
    volumes:
      - omniroute-data:/home/node/.omniroute

volumes:
  omniroute-data:
```

Create a `.env` file next to `docker-compose.yml`:

```env
NVIDIA_API_KEY=nvapi-...
OPENROUTER_API_KEY=sk-or-...
GEMINI_API_KEY=...
```

Start OmniRoute:

```bash
docker compose up -d
```

Then create an OmniRoute API key in the dashboard (http://localhost:20128 → Endpoints) and export it:

```bash
export OMNIROUTE_API_KEY='omni-...'
```

Now create sandboxes that point at OmniRoute:

```bash
openshell sandbox create \
  --name claude-code-agent \
  --from <your-claude-code-image> \
  --provider omniroute \
  --env OMNIROUTE_API_KEY="${OMNIROUTE_API_KEY}" \
  --env ANTHROPIC_BASE_URL=http://host.openshell.internal:20128/v1 \
  --env ANTHROPIC_AUTH_TOKEN="${OMNIROUTE_API_KEY}" \
  --detach \
  -- sh -c 'sleep 86400'
```

---

## Provider credentials

Declare upstream provider API keys using system environment variables, passed to the OmniRoute container at runtime (do not bake them into the image). OmniRoute reads them as provider fallbacks:

- `NVIDIA_API_KEY` — NVIDIA NIM
- `OPENROUTER_API_KEY` — OpenRouter
- `GEMINI_API_KEY` / `GOOGLE_API_KEY` — Google Gemini
- `DEEPSEEK_API_KEY` — DeepSeek
- `JINA_AI_API_KEY` / `JINA_API_KEY` — Jina AI

Example with `docker run`:

```bash
docker run -d \
  --name omniroute \
  --restart unless-stopped \
  -p 20128:20128 \
  -e INITIAL_PASSWORD='change-this-password' \
  -e REQUIRE_API_KEY='true' \
  -e NVIDIA_API_KEY="${NVIDIA_API_KEY}" \
  -e OPENROUTER_API_KEY="${OPENROUTER_API_KEY}" \
  -e GEMINI_API_KEY="${GEMINI_API_KEY}" \
  -v omniroute-data:/home/node/.omniroute \
  fibonsai/omniroute-docker
```

Or with an `--env-file` where `provider.env` contains:

```
NVIDIA_API_KEY=sk-or-...
OPENROUTER_API_KEY=sk-or-...
GEMINI_API_KEY=...
DEEPSEEK_API_KEY=sk-...
JINA_AI_API_KEY=...
```

For any other provider, set its `*_API_KEY` variable the same way at runtime. OmniRoute reads provider keys from its environment. Do not store provider keys in OmniRoute's SQLite database — the database must not become a credential store. The sandbox agent (OpenShell) only ever sees `OMNIROUTE_API_KEY`, never upstream provider keys.

Provider-specific variables for other supported providers are documented in OmniRoute's [environment reference](https://github.com/diegosouzapw/OmniRoute/blob/main/docs/reference/ENVIRONMENT.md).

---

## Credential security

The sandbox agent never holds upstream provider keys. It only sees `OMNIROUTE_API_KEY` (an opaque placeholder managed by OpenShell) and reaches OmniRoute at `host.openshell.internal:20128/v1`. Upstream provider keys come through OmniRoute's system environment at startup (`NVIDIA_API_KEY`, `OPENROUTER_API_KEY`, `GEMINI_API_KEY`/`GOOGLE_API_KEY`, `DEEPSEEK_API_KEY`, `JINA_AI_API_KEY`/`JINA_API_KEY`) and are never stored in OmniRoute's database for this flow. Even if the sandbox is compromised, the attacker cannot extract upstream API keys.

> **Why not add every upstream provider to OpenShell?** The sandbox does not call the upstream APIs; it calls OmniRoute. Adding `api.openai.com`, `api.anthropic.com`, and the rest to the sandbox policy would expose their credentials to the agent and bypass OmniRoute's routing, retries, and accounting. Keep one OpenShell provider for OmniRoute and declare upstream keys through OmniRoute's system environment at startup.

---

## Persistence

Mount a volume at OmniRoute's data directory (`/home/node/.omniroute`). That directory holds `storage.sqlite`, the generated secrets in `.env`, database backups, and installed plugins. Without a volume, all configuration is lost when the container is removed.

For Claude Code's own data (conversation history, config), mount a volume or bind-mount into `/workspace` or `~claude/.config` depending on your image setup.

---

## Operations

### Logs

```bash
docker logs -f omniroute
```

### Shell into OmniRoute

```bash
docker exec -it omniroute sh
```

### Reset the OmniRoute dashboard password

```bash
docker exec -it omniroute omniroute reset-password
```

### Upgrade OmniRoute

```bash
docker compose pull
docker compose up -d
```

Because the database and generated secrets live in the data volume, keeping it means existing API keys and the encryption key survive the upgrade.

---

## Smoke-test from a sandbox

```bash
openshell sandbox create \
  --name omniroute-smoke \
  --from docker.io/curlimages/curl:latest \
  --provider omniroute \
  --env OPENAI_BASE_URL=http://host.openshell.internal:20128/v1 \
  -- sh -c 'curl -fsS "$OPENAI_BASE_URL/chat/completions" \
    -H "Authorization: Bearer $OMNIROUTE_API_KEY" \
    -H "Content-Type: application/json" \
    -d "{\"model\":\"auto\",\"messages\":[{\"role\":\"user\",\"content\":\"Reply with OK\"}]}"'
```

A JSON completion means the sandbox reached OmniRoute, OpenShell substituted the real OmniRoute key, and OmniRoute routed to one of the connected providers.

To clean up:

```bash
openshell sandbox delete omniroute-smoke omniroute-agent claude-code-agent
```

---

## OpenShell troubleshooting

| Symptom | Fix |
| --- | --- |
| `credential_endpoint_mismatch` | The profile's `endpoints` host, port, or path does not match the URL the agent calls. `host.openshell.internal` is not `localhost`; use the exact host declared in the profile. |
| Connection refused or timeout to `host.openshell.internal:20128` | OmniRoute is not reachable from the sandbox. Confirm the port is published, the host address is correct for your gateway (host-local, Docker network, or LAN), and the profile declares that host. |
| `403` or policy denial | Check `openshell policy get <sandbox> --full`; the provider must be attached and its `binaries` must include the calling executable (for example `/usr/local/bin/opencode` or `/usr/bin/curl`). |
| `401` from OmniRoute | The OmniRoute key is wrong, or `REQUIRE_API_KEY` is enabled without a valid key. Export the correct `OMNIROUTE_API_KEY` and recreate the provider with `--from-existing`. |
| `429` or upstream provider errors | The selected provider failed or has no key. Check OmniRoute's logs and confirm the provider key is set in OmniRoute's system environment at startup (see [Provider credentials](#provider-credentials)). |

---

## Links

- This image's Dockerfile: [`Dockerfile`](./Dockerfile)
- OmniRoute Docker image: [https://github.com/fibonsai/omniroute-docker](https://github.com/fibonsai/omniroute-docker)
- Upstream OmniRoute project: [https://github.com/diegosouzapw/OmniRoute](https://github.com/diegosouzapw/OmniRoute)
- OmniRoute website and docs: [https://omniroute.online](https://omniroute.online)
- npm package: [https://www.npmjs.com/package/omniroute](https://www.npmjs.com/package/omniroute)
- NVIDIA OpenShell: [https://docs.nvidia.com/openshell/](https://docs.nvidia.com/openshell/)
- OpenShell provider profiles: [https://docs.nvidia.com/openshell/latest/how-it-works/providers/profiles](https://docs.nvidia.com/openshell/latest/how-it-works/providers/profiles)
- OpenCode provider configuration: [https://opencode.ai/v2/docs/providers](https://opencode.ai/v2/docs/providers)
- Claude Code: [https://claude.ai/code](https://claude.ai/code)

---

## License

The packaging files in this repository are provided as-is. OmniRoute is distributed under the MIT License; see the [upstream license](https://github.com/diegosouzapw/OmniRoute/blob/main/LICENSE).
