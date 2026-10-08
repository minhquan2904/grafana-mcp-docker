# grafana-mcp-docker

Run the official [Grafana MCP server](https://github.com/grafana/mcp-grafana) in Docker,
read-only by default, behind a small nginx proxy that decides who may call it. Your
Grafana service account token stays on the host; clients never see it.

```
MCP client ──Bearer <client token>──► proxy (nginx, BIND_IP:BIND_PORT)
                                        │ AUTH_MODE decides who is allowed
                                        ▼ swaps in the server token
                         mcp-grafana (no published port) ──► your Grafana
```

| `AUTH_MODE` | Use it when | Client sends |
|---|---|---|
| `none` (default) | Only you, on your own machine. Forced to `127.0.0.1`. | nothing |
| `static` | Sharing with a few people. One token per person. | `Bearer <their token>` |
| `authz` | You already run an SSO / auth gateway (e.g. one built on nginx `auth_request`). | whatever your gateway issues |

## Requirements

- Docker with Compose v2 (Docker Desktop on macOS/Windows, Docker Engine on Linux)
- `bash`, `openssl`, `curl` (macOS and Linux have them; Windows: see [below](#windows))
- A Grafana service account token. In Grafana: *Administration → Users and access →
  Service accounts → Add*, role **Viewer**, then *Add service account token*.

## Quick start (local)

```bash
git clone https://github.com/minhquan2904/grafana-mcp-docker.git
cd grafana-mcp-docker
cp .env.example .env            # fill in GRAFANA_URL and GRAFANA_SERVICE_ACCOUNT_TOKEN
./start.sh up                   # starts both containers and runs a smoke test
```

Add it to your MCP client. Claude Code:

```bash
claude mcp add --transport http -s user grafana http://127.0.0.1:18090/mcp
```

Other clients (Cursor, VS Code, ...) take the same URL as a "streamable HTTP" server.

### Even simpler: no proxy at all

If it is only for you and you do not need a long-running server, let the client start
the container itself over stdio. Only Docker is needed:

```bash
claude mcp add -s user grafana \
  -e GRAFANA_URL=https://grafana.example.com/ \
  -e GRAFANA_SERVICE_ACCOUNT_TOKEN=glsa_xxx \
  -- docker run --rm -i -e GRAFANA_URL -e GRAFANA_SERVICE_ACCOUNT_TOKEN \
     grafana/mcp-grafana:1.6.3 -t stdio --disable-write
```

PowerShell (one line, or use a backtick `` ` `` instead of `\` to continue lines):

```powershell
claude mcp add -s user grafana -e GRAFANA_URL=https://grafana.example.com/ -e GRAFANA_SERVICE_ACCOUNT_TOKEN=glsa_xxx -- docker run --rm -i -e GRAFANA_URL -e GRAFANA_SERVICE_ACCOUNT_TOKEN grafana/mcp-grafana:1.6.3 -t stdio --disable-write
```

## Sharing with your team (`AUTH_MODE=static`)

1. Put the host on a network only your team can reach (a VPN or Tailscale is
   the easy option) and set in `.env`:
   ```bash
   AUTH_MODE=static
   BIND_IP=100.x.y.z        # e.g. `tailscale ip -4`; avoid 0.0.0.0 on public hosts
   ```
2. `./start.sh up`
3. Create one token per person and send it privately:
   ```bash
   ./start.sh add-client alice      # prints the token once
   ./start.sh list-clients
   ./start.sh remove-client alice   # revoke; takes effect immediately
   ```
4. Each person adds:
   ```bash
   claude mcp add --transport http -s user grafana http://100.x.y.z:18090/mcp \
     --header "Authorization: Bearer <their token>"
   ```

The proxy access log records which client made each call (`./start.sh logs`).

Tokens are plain HTTP bearer tokens. Without TLS, anyone who can sniff the network
path can read them, which is why a VPN/Tailscale network is recommended. To expose
it more widely, put it behind your own HTTPS reverse proxy.

## Using an existing auth gateway (`AUTH_MODE=authz`)

```bash
AUTH_MODE=authz
AUTHZ_URL=https://sso.example.com/authz/grafana
```

For every `/mcp` request nginx sends the client's `Authorization` header (no body) to
`AUTHZ_URL` and expects:

- `2xx` → allowed. An optional `X-MCP-Gateway-User` response header is logged as the caller.
- `401` / `403` → rejected; the client gets a JSON error.

The gateway never needs the Grafana token; this host swaps it in after the check.
If the gateway is down, requests fail (fail closed).

## Windows

Use **WSL2** with **Docker Desktop** (WSL 2 backend).

1. Install WSL2 (`wsl --install` in an admin PowerShell, then reboot) and Docker Desktop.
   In Docker Desktop: *Settings → Resources → WSL integration* → enable your distro.
2. Open the WSL terminal (e.g. *Ubuntu*) and clone **inside the WSL filesystem**
   (`~/...`, not `/mnt/c/...`). Bind mounts from `/mnt/c` are slow and lose Unix permissions.
   ```bash
   sudo apt-get install -y openssl curl   # usually already there
   git clone https://github.com/minhquan2904/grafana-mcp-docker.git
   cd grafana-mcp-docker
   cp .env.example .env && nano .env
   ./start.sh up
   ```
3. Ports published from WSL are forwarded to Windows `localhost`, so a client running
   on Windows uses the same URL: `http://127.0.0.1:18090/mcp`.

If you only need it for yourself, the PowerShell command in
[Even simpler](#even-simpler-no-proxy-at-all) needs only Docker Desktop, no WSL shell.

If `./start.sh` fails with `$'\r': command not found`, the files have Windows line
endings. This repo pins LF in `.gitattributes`; re-clone inside WSL instead of copying
from a Windows folder.

## Operations

| Task | Command |
|---|---|
| Start / apply `.env` changes | `./start.sh up` |
| Smoke test | `./start.sh smoke` (`static`/`authz`: `SMOKE_TOKEN=... ./start.sh smoke`) |
| Logs | `./start.sh logs` |
| Stop | `./start.sh down` |
| Rotate the Grafana token | edit `.env`, `./start.sh up` |
| Rotate the internal server token | empty `MCP_GRAFANA_SERVER_TOKEN` in `.env`, `./start.sh up` |
| Allow write tools | delete `--disable-write` in `docker-compose.yml`, give the SA an Editor role |

Grafana on a private DNS name the container cannot resolve? Add to the `mcp-grafana`
service in `docker-compose.yml`:

```yaml
    extra_hosts:
      - "grafana.private.example:10.0.0.10"
```

## Hardening already in place

- `mcp-grafana` has no published port; only the proxy can reach it.
- Both containers: read-only root FS, `no-new-privileges`, all capabilities dropped
  (nginx keeps only CHOWN/SETUID/SETGID to drop to its worker user), memory and PID limits.
- Secrets live in `.env` (600) and `.secrets/` (700), both git-ignored.
- `AUTH_MODE=none` refuses to start on a non-loopback address.
