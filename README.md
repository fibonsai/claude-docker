# claude-docker

A minimal Alpine image that runs **[Claude Code](https://claude.ai/code)** (the official Anthropic CLI) as the unprivileged `claude` user.

It also ships the pieces needed to run Claude Code in an **[NVIDIA OpenShell](https://docs.nvidia.com/openshell/)** sandbox through **[OmniRoute](https://github.com/cheaper-inference/OmniRoute)**: an agent provider profile, a filesystem policy, and the `run-claude` launcher.

---

## Repository layout

| Path | Purpose |
| --- | --- |
| `Dockerfile` | Builds the Claude Code image. |
| `openshell/omniroute.yaml` | OpenShell provider profile for the Claude Code sandbox. Exposes only OmniRoute's API. |
| `openshell/policy.yaml` | Filesystem policy for the Claude Code sandbox. |
| `run-claude` | Creates a sandbox, uploads a workspace, runs Claude Code, and cleans up. |

---

## Quick start: standalone

Build the image and run Claude Code directly against Anthropic:

```bash
docker build -t claude-docker .

docker run -it --rm \
  --name claude-code \
  -e ANTHROPIC_API_KEY="${ANTHROPIC_API_KEY}" \
  -v "$PWD:/workspace" \
  -w /workspace \
  claude-docker \
  /home/claude/.local/bin/claude
```

The image installs the CLI under `/home/claude/.local/bin` and adds it to `PATH`.

---

## Quick start: OpenShell + OmniRoute (recommended)

Claude Code talks the Anthropic Messages API. OmniRoute exposes an Anthropic/OpenAI-compatible gateway, so Claude Code points at OmniRoute with `ANTHROPIC_BASE_URL` and authenticates with an OmniRoute key.

```
Claude Code (OpenShell sandbox)
        │  ANTHROPIC_AUTH_TOKEN = OMNIROUTE_API_KEY placeholder
        ▼
OmniRoute :20128   (Anthropic + OpenAI-compatible gateway)
        │  real upstream keys (never enter the sandbox)
        ▼
NVIDIA NIM, OpenAI, Anthropic, Gemini, OpenRouter, ...
```

The sandbox sees only an opaque placeholder managed by OpenShell. Upstream `{PROVIDER}_API_KEY` values stay in OmniRoute's own environment.

### Prerequisites

- Docker or Podman, with the matching OpenShell gateway configured
- The `openshell` CLI
- An OmniRoute instance reachable from the sandbox
- An OmniRoute API key

### 1. Start OmniRoute

Use the companion image from [`fibonsai/omniroute-docker`](https://github.com/fibonsai/omniroute-docker), or run OmniRoute inside OpenShell with that repository's `run-omniroute.sh`.

Standalone Docker example:

```bash
git clone https://github.com/fibonsai/omniroute-docker.git
cd omniroute-docker
docker build -t fibonsai/omniroute .

docker run -d \
  --name omniroute \
  --restart unless-stopped \
  -p 20128:20128 \
  -e INITIAL_PASSWORD='change-this-password' \
  -e REQUIRE_API_KEY='true' \
  -e NVIDIA_API_KEY="${NVIDIA_API_KEY}" \
  -e OPENROUTER_API_KEY="${OPENROUTER_API_KEY}" \
  -v omniroute-data:/home/node/.omniroute \
  fibonsai/omniroute omniroute --no-open
```

Open <http://localhost:20128>, log in with `INITIAL_PASSWORD`, create an API key under **Endpoints**, and export it:

```bash
export OMNIROUTE_API_KEY='sk-...'
```

Upstream provider keys must be present in OmniRoute's environment **before** it starts. Do not store them in the sandbox or bake them into an image.

### 2. Run Claude Code

From this repository:

```bash
export OMNIROUTE_API_KEY='sk-...'
./run-claude
```

One-shot prompt:

```bash
./run-claude "Summarize the files in this workspace."
```

`run-claude` does the following:

1. Loads `OMNIROUTE_API_KEY` from the environment, or from `.env` in the current directory (falling back to `.env` in this repository).
2. Builds `claude-docker` if the image is missing.
3. Recreates `openshell/omniroute.yaml` and the `omniroute-agent` provider from `OMNIROUTE_API_KEY`.
4. Creates an OpenShell sandbox with `openshell/policy.yaml`, the provider, and `ANTHROPIC_BASE_URL` pointing at OmniRoute.
5. Uploads the current directory to `/sandbox` (Git-aware; `.gitignore` rules apply).
6. Runs `/home/claude/.local/bin/claude` and deletes the sandbox when it exits.

`run-claude` copies OpenShell's opaque `OMNIROUTE_API_KEY` placeholder into `ANTHROPIC_AUTH_TOKEN` inside the sandbox, so Claude Code authenticates to OmniRoute without the real key ever entering the sandbox.

The profile and provider are recreated on every run so a changed YAML or key is always applied. Keep the `omniroute-agent` names dedicated to this launcher; deleting the provider invalidates other sandboxes that use it.

Pass extra flags through to Claude Code:

```bash
./run-claude --model auto "Explain the Dockerfile."
```

#### Configuration

| Variable | Default | Meaning |
| --- | --- | --- |
| `OMNIROUTE_API_KEY` | environment or `.env` | OmniRoute API key. Required. |
| `OMNIROUTE_ORIGIN` | auto-detected | Gateway origin **without** `/v1`, e.g. `http://host.docker.internal:20128`. |
| `OMNIROUTE_PORT` | `20128` | Port used when auto-detecting the origin. |
| `CLAUDE_IMAGE` | `claude-docker` | Container image to run. |
| `CLAUDE_SANDBOX` | `claude-code` | Sandbox name. An existing sandbox with this name is replaced. |
| `CLAUDE_WORKSPACE` | current directory | Host directory uploaded to the sandbox. |
| `CLAUDE_WORKDIR` | `/sandbox/<basename>` | Working directory used inside the sandbox. |
| `ANTHROPIC_MODEL` | unset | Optional model id passed to Claude Code. |
| `BUILD_IMAGE` | `auto` | `auto` (build only when missing), `1` (always), `0` (never). |
| `UPLOAD` | `1` | Set to `0` to skip uploading `CLAUDE_WORKSPACE`. |
| `KEEP_SANDBOX` | `0` | Set to `1` to keep the sandbox after Claude Code exits. |
| `OMNIROUTE_ENV_FILE` | `./.env`, then repo `.env` | File used to read `OMNIROUTE_API_KEY`. |

#### Gateway address

Claude Code must use the gateway origin, **not** `/v1`; it appends `/v1/messages` itself.

| Sandbox location | OmniRoute origin |
| --- | --- |
| Docker-backed gateway | `http://host.openshell.internal:20128` |
| Podman-backed gateway | `http://host.docker.internal:20128` |
| Outside OpenShell | the service URL from `openshell service list` |

`run-claude` reads `compute_driver` from `~/.config/openshell/gateway.toml` and picks the matching host alias. Override it with `OMNIROUTE_ORIGIN` if OmniRoute runs elsewhere:

```bash
export OMNIROUTE_ORIGIN='http://192.168.0.15:20128'
```

### 3. Inspect or clean up

When `KEEP_SANDBOX=1` is set:

```bash
openshell sandbox exec -n claude-code --workdir /sandbox -- ls -la
openshell sandbox delete claude-code
```

To inspect the effective policy and provider binding:

```bash
openshell policy get claude-code --full
openshell sandbox get claude-code
```

---

## What the OpenShell profile enforces

`openshell/omniroute.yaml`:

- **One credential, one placeholder.** The sandbox receives only `OMNIROUTE_API_KEY`, an opaque placeholder. `run-claude` copies it into `ANTHROPIC_AUTH_TOKEN` when it launches Claude Code.
- **One reachable endpoint.** Only `/v1/**` on OmniRoute's port is allowed. The dashboard and upstream provider endpoints are blocked.
- **Both host aliases.** `host.openshell.internal` (Docker) and `host.docker.internal` (Podman) are declared so the profile works on either gateway.
- **Binary allowlist.** Only `claude`, `node`, and `curl` may call the endpoint.

`openshell/policy.yaml`:

- The OpenShell-managed `/sandbox` workspace is writable.
- System paths (`/bin`, `/usr`, `/lib`, `/etc`, `/opt`, …) are read-only.
- `/tmp`, `/dev/null`, `/dev/tty`, and `/home/claude` are writable so Claude Code can keep its settings and session files.

---

## Security model

- **Upstream keys never enter the agent sandbox.** OmniRoute holds them in its own environment and routes each request.
- **OpenShell resolves placeholders at the endpoint.** The sandbox cannot read the real OmniRoute key; it only sees a placeholder that the gateway swaps when a request targets the declared endpoint.
- **Claude Code receives the placeholder, not the key.** `run-claude` exports the placeholder as `ANTHROPIC_AUTH_TOKEN` at process launch; OpenShell substitutes the real credential only inside the approved OmniRoute request.
- **No direct provider access.** The agent profile allows only OmniRoute's `/v1/**`; `api.openai.com`, `api.anthropic.com`, and similar hosts are unreachable.
- **The sandbox is unprivileged.** The image runs Claude Code as `claude`, not root.
- **The sandbox is ephemeral by default.** `run-claude` deletes it on exit and uploads the workspace from the host each run.

Do not add upstream provider keys to the agent sandbox, and do not widen the profile to the OmniRoute dashboard or provider hosts.

---

## Persistence

The Claude Code sandbox is disposable in this workflow. Keep the workspace in Git (or on the host) and let `run-claude` upload it on each run. If you need to preserve files written inside the sandbox, set `KEEP_SANDBOX=1` and download them before deleting the sandbox.

---

## Troubleshooting

| Symptom | Fix |
| --- | --- |
| `OMNIROUTE_API_KEY is not set` | Export the key or write `OMNIROUTE_API_KEY=...` to `.env`. |
| `image 'claude-docker' not found` | Run `docker build -t claude-docker .`, or set `CLAUDE_IMAGE` to your tag. |
| `profile not found` / profile errors | Run `openshell profile lint -f openshell/omniroute.yaml`, then re-run `run-claude`. |
| `WorkspaceValidationFailed: OCI WorkingDir is not usable` | The image's `WORKDIR` must be `/sandbox` for OpenShell's managed workspace volume. Rebuild with this repository's Dockerfile, or set `CLAUDE_IMAGE` to an image that uses `/sandbox`. |
| Claude Code ignores the gateway | `ANTHROPIC_BASE_URL` must be the origin **without** `/v1`. Restart the sandbox after changing it; Claude Code reads the variable at startup. |
| `401` from OmniRoute | The key is wrong or revoked. Re-export `OMNIROUTE_API_KEY`; `run-claude` recreates the provider on every run. |
| `403` or a policy denial | The request must target `/v1/**` on the declared host, and the calling binary must be in the profile's `binaries` allowlist. Check with `openshell policy get claude-code --full`. |
| `credential_endpoint_mismatch` | The profile host, port, or path does not match the URL Claude Code calls. Use `host.openshell.internal` on Docker, `host.docker.internal` on Podman, or set `OMNIROUTE_ORIGIN` to the exact reachable origin. |
| Connection refused or timeout | OmniRoute is not reachable from the sandbox. Confirm port `20128` is published and that the origin matches your gateway's host alias. On Podman, `host.openshell.internal` does not exist; use `host.docker.internal`. |
| `/model` picker is empty | Set `ANTHROPIC_MODEL` to an exposed model id, or enable discovery with `CLAUDE_CODE_ENABLE_GATEWAY_MODEL_DISCOVERY=1` (already set by `run-claude`). |
| Upload is slow or too large | Set `UPLOAD=0` and work with a pre-populated image, or point `CLAUDE_WORKSPACE` at a smaller directory. |

---

## Links

- Claude Code: <https://claude.ai/code>
- OmniRoute Docker packaging: <https://github.com/fibonsai/omniroute-docker>
- OmniRoute upstream: <https://github.com/cheaper-inference/OmniRoute>
- OmniRoute website and docs: <https://omniroute.online>
- OmniRoute on npm: <https://www.npmjs.com/package/omniroute>
- NVIDIA OpenShell: <https://docs.nvidia.com/openshell/>
- OpenShell provider profiles: <https://docs.nvidia.com/openshell/latest/how-it-works/providers/profiles>

---

## License

The packaging files in this repository are provided as-is. OmniRoute is distributed under the MIT License; see the [upstream license](https://github.com/cheaper-inference/OmniRoute/blob/main/LICENSE).
