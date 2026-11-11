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
Claude Code / curl (sandbox)
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
  - /home/claude/.local/bin/claude
  - /usr/local/bin/node
  - /usr/bin/curl
  - /usr/local/bin/curl
```

The profile enforces strict credential-to-endpoint binding:

- **Sandbox sees only `OMNIROUTE_API_KEY`.** Upstream `{PROVIDER}_API_KEY` values never enter the sandbox.
- **`path: /v1/**`** limits the sandbox to OmniRoute's OpenAI-compatible API; the dashboard and every other host are unreachable.
- **`enforcement: enforce`** blocks any request outside the allowed endpoint.
- **`binaries` allowlist** restricts which processes may use the endpoint to `claude` (at `/home/claude/.local/bin/claude`), `node`, and `curl`.

Lint, import, and create the provider:

```bash
openshell profile lint -f openshell/omniroute.yaml
openshell profile import -f openshell/omniroute.yaml
openshell provider create --name omniroute --type omniroute --from-existing
```

`--from-existing` reads `OMNIROUTE_API_KEY` from your shell and stores it in OpenShell; the sandbox receives only an opaque placeholder.

### Step 3 — Run Claude Code through OmniRoute

This project's Dockerfile installs the Claude Code CLI at `/home/claude/.local/bin/claude`. Build your own image from this repo and reference it as `<your-claude-code-image>`. Run it inside an `omniroute` sandbox so it reaches OmniRoute — and therefore every connected provider — without holding any upstream `{PROVIDER}_API_KEY`:

```bash
openshell sandbox create \
  --name claude-code-agent \
  --from <your-claude-code-image> \
  --provider omniroute \
  --env ANTHROPIC_BASE_URL=http://host.openshell.internal:20128/v1 \
  --env ANTHROPIC_AUTH_TOKEN="${OMNIROUTE_API_KEY}" \
  --detach \
  -- sh -c 'sleep 86400'

openshell sandbox exec -n claude-code-agent --workdir /workspace -- \
  /home/claude/.local/bin/claude "Summarize the files in this workspace."
```

Claude Code authenticates to OmniRoute with `OMNIROUTE_API_KEY`, and OmniRoute routes to the configured provider (e.g. NVIDIA NIM, OpenAI, Gemini). The Claude Code sandbox never sees `NVIDIA_API_KEY`, `GEMINI_API_KEY`, or any other upstream key.

Claude Code uses `ANTHROPIC_BASE_URL` and `ANTHROPIC_AUTH_TOKEN` to point at any OpenAI-compatible endpoint, so OmniRoute's `/v1/chat/completions` works as a drop-in replacement for the Anthropic API.

## Credential security

The sandbox agent never holds upstream provider keys. It only sees `OMNIROUTE_API_KEY` (an opaque placeholder managed by OpenShell) and reaches OmniRoute at `host.openshell.internal:20128/v1`. Upstream provider keys come through OmniRoute's system environment at startup (`NVIDIA_API_KEY`, `OPENROUTER_API_KEY`, `GEMINI_API_KEY`/`GOOGLE_API_KEY`, `DEEPSEEK_API_KEY`, `JINA_AI_API_KEY`/`JINA_API_KEY`) and are never stored in OmniRoute's database for this flow. Even if the sandbox is compromised, the attacker cannot extract upstream API keys.

> **Why not add every upstream provider to OpenShell?** The sandbox does not call the upstream APIs; it calls OmniRoute. Adding `api.openai.com`, `api.anthropic.com`, and the rest to the sandbox policy would expose their credentials to the agent and bypass OmniRoute's routing, retries, and accounting. Keep one OpenShell provider for OmniRoute and declare upstream keys through OmniRoute's system environment at startup.

---

## Persistence

Mount a volume at OmniRoute's data directory (`/home/node/.omniroute`). That directory holds `storage.sqlite`, the generated secrets in `.env`, database backups, and installed plugins. Without a volume, all configuration is lost when the container is removed.

For Claude Code's own data (conversation history, config), mount a volume or bind-mount into `/workspace` or `~claude/.config` depending on your image setup.

---

## OpenShell troubleshooting

| Symptom | Fix |
| --- | --- |
| `credential_endpoint_mismatch` | The profile's `endpoints` host, port, or path does not match the URL the agent calls. `host.openshell.internal` is not `localhost`; use the exact host declared in the profile. |
| Connection refused or timeout to `host.openshell.internal:20128` | OmniRoute is not reachable from the sandbox. Confirm the port is published, the host address is correct for your gateway (host-local, Docker network, or LAN), and the profile declares that host. |
| `403` or policy denial | Check `openshell policy get <sandbox> --full`; the provider must be attached and its `binaries` must include the calling executable (for example `/home/claude/.local/bin/claude` or `/usr/bin/curl`). |
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
- Claude Code: [https://claude.ai/code](https://claude.ai/code)

---

## License

The packaging files in this repository are provided as-is. OmniRoute is distributed under the MIT License; see the [upstream license](https://github.com/diegosouzapw/OmniRoute/blob/main/LICENSE).
