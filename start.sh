#!/usr/bin/env bash
# Grafana MCP behind an nginx auth proxy — see README.md.
#
#   ./start.sh prepare              check .env, generate server token, render .secrets/
#   ./start.sh up                   prepare + compose up -d + smoke
#   ./start.sh smoke                healthz + auth check (+ MCP calls, see README)
#   ./start.sh add-client <name>    AUTH_MODE=static: create a token, print it once
#   ./start.sh remove-client <name>
#   ./start.sh list-clients
#   ./start.sh down | logs | ps
set -Eeuo pipefail
umask 077
cd "$(dirname "$0")"

info() { printf '[INFO] %s\n' "$*"; }
ok()   { printf '[OK] %s\n' "$*"; }
die()  { printf '[ERROR] %s\n' "$*" >&2; exit 1; }

CLIENTS=.secrets/clients.txt

compose() {
  docker compose --env-file .env "$@"
}

env_value() {
  grep -E "^$1=" .env | tail -1 | cut -d= -f2- || true
}

# Portable replacement for `sed -i` (BSD and GNU differ).
set_env() {
  local key="$1" value="$2" tmp
  tmp="$(mktemp .env.XXXXXX)"
  { grep -vE "^${key}=" .env || true; printf '%s=%s\n' "$key" "$value"; } > "$tmp"
  chmod 600 "$tmp"
  mv "$tmp" .env
}

new_token() { openssl rand -hex 32; }

ensure_secrets_dir() {
  mkdir -p .secrets/nginx
  chmod 700 .secrets
  chmod 755 .secrets/nginx
}

# Atomic write of a file nginx reads: 644 so nginx (root, cap_drop ALL) can read it
# through the bind mount; the 700 .secrets/ parent keeps other host users out.
write_public() {
  local dest="$1" tmp
  tmp="$(mktemp "$dest.XXXXXX")"
  cat > "$tmp"
  chmod 644 "$tmp"
  mv "$tmp" "$dest"
}

render_clients_map() {
  local name token
  {
    printf 'map $http_authorization $mcp_user {\n    default "";\n'
    if [[ -f $CLIENTS ]]; then
      while read -r name token; do
        [[ -n ${name:-} ]] && printf '    "Bearer %s" "%s";\n' "$token" "$name"
      done < "$CLIENTS"
    fi
    printf '}\n'
  } | write_public .secrets/nginx/clients.map
}

render_authz() {
  local url host
  url="$(env_value AUTHZ_URL)"
  if [[ -z $url ]]; then
    printf 'set $authz_url "";\n' | write_public .secrets/nginx/authz.conf
    return
  fi
  # Strict charset: the value lands inside nginx config.
  [[ $url =~ ^https?://([A-Za-z0-9.-]+(:[0-9]+)?)(/[A-Za-z0-9._~/%-]*)?$ ]] \
    || die "AUTHZ_URL is not a plain http(s) URL: $url"
  host="${BASH_REMATCH[1]}"
  printf 'set $authz_url "%s";\nproxy_set_header Host %s;\n' "$url" "$host" \
    | write_public .secrets/nginx/authz.conf
}

is_loopback() {
  [[ $1 == 127.* || $1 == localhost ]]
}

cmd_prepare() {
  [[ -f .env ]] || die "Missing .env — cp .env.example .env, then fill it in"
  chmod 600 .env

  [[ -n $(env_value GRAFANA_URL) ]] || die "GRAFANA_URL is empty in .env"
  [[ -n $(env_value GRAFANA_SERVICE_ACCOUNT_TOKEN) ]] || die "GRAFANA_SERVICE_ACCOUNT_TOKEN is empty in .env"

  local mode bind_ip
  mode="$(env_value AUTH_MODE)"
  bind_ip="$(env_value BIND_IP)"
  [[ -n $bind_ip ]] || die "BIND_IP is empty in .env"
  case "$mode" in
    none)
      is_loopback "$bind_ip" \
        || die "AUTH_MODE=none would let anyone on $bind_ip use your Grafana token. Use BIND_IP=127.0.0.1, or AUTH_MODE=static" ;;
    static)
      [[ -s $CLIENTS ]] || info "No clients yet: ./start.sh add-client <name>" ;;
    authz)
      [[ -n $(env_value AUTHZ_URL) ]] || die "AUTH_MODE=authz needs AUTHZ_URL" ;;
    *)
      die "AUTH_MODE must be none, static or authz (got '${mode}')" ;;
  esac
  [[ $bind_ip != 0.0.0.0 ]] || info "BIND_IP=0.0.0.0 listens on every interface; make sure that is what you want"

  if [[ -z $(env_value MCP_GRAFANA_SERVER_TOKEN) ]]; then
    set_env MCP_GRAFANA_SERVER_TOKEN "$(new_token)"
    info "Generated MCP_GRAFANA_SERVER_TOKEN"
  fi

  ensure_secrets_dir
  printf 'proxy_set_header Authorization "Bearer %s";\n' "$(env_value MCP_GRAFANA_SERVER_TOKEN)" \
    | write_public .secrets/nginx/upstream-auth.conf
  render_clients_map
  render_authz

  compose config --quiet
  ok "prepare done (AUTH_MODE=$mode)"
}

base_url() {
  printf 'http://%s:%s' "$(env_value BIND_IP)" "$(env_value BIND_PORT)"
}

mcp_post() {
  local token="$1" body="$2" auth=()
  [[ -n $token ]] && auth=(-H "Authorization: Bearer ${token}")
  curl -sS --max-time 30 -X POST "$(base_url)/mcp" \
    "${auth[@]+"${auth[@]}"}" \
    -H 'Content-Type: application/json' \
    -H 'Accept: application/json, text/event-stream' \
    -d "$body"
}

cmd_smoke() {
  local base code mode token out
  base="$(base_url)"
  mode="$(env_value AUTH_MODE)"

  code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "$base/healthz")"
  [[ $code == 200 ]] || die "healthz: $code"
  ok "healthz 200"

  if [[ $mode == none ]]; then
    token=""
  else
    code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 -X POST "$base/mcp")"
    [[ $code == 401 ]] || die "/mcp without a token should be 401, got $code"
    ok "/mcp without a token: 401"
    token="${SMOKE_TOKEN:-}"
    if [[ -z $token ]]; then
      info "Skipping MCP calls: export SMOKE_TOKEN=<client token> to run them"
      return 0
    fi
  fi

  out="$(mcp_post "$token" '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"smoke","version":"0"}}}')"
  grep -q '"serverInfo"' <<<"$out" || die "initialize failed: ${out:0:300}"
  ok "initialize"
  # mcp-grafana streamable-http is stateless by default: no session id needed.
  out="$(mcp_post "$token" '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"search_dashboards","arguments":{"query":""}}}')"
  grep -q '"result"' <<<"$out" && ! grep -q '"isError":true' <<<"$out" \
    || die "tools/call search_dashboards failed (check GRAFANA_URL and the SA token): ${out:0:300}"
  ok "tools/call search_dashboards"
}

valid_name() {
  [[ ${1:-} =~ ^[A-Za-z0-9._-]{1,64}$ ]] || die "Client name must match [A-Za-z0-9._-]{1,64}"
}

reload_proxy() {
  if [[ -n $(compose ps -q proxy 2>/dev/null) ]]; then
    compose exec -T proxy nginx -s reload || return 1
    # reload only signals the master; give new workers a moment so "added" /
    # "removed" is true when this returns.
    sleep 2
    ok "proxy reloaded"
  fi
}

cmd_add_client() {
  local name="${1:-}" token
  valid_name "$name"
  ensure_secrets_dir
  touch "$CLIENTS" && chmod 600 "$CLIENTS"
  ! grep -qE "^${name} " "$CLIENTS" || die "Client '$name' exists; remove-client first to rotate"
  token="$(new_token)"
  printf '%s %s\n' "$name" "$token" >> "$CLIENTS"
  render_clients_map
  if ! reload_proxy; then
    # Do not keep a token the running proxy never accepted.
    drop_client "$name"
    reload_proxy || true
    die "proxy rejected the new config; client '$name' not added"
  fi
  ok "Client '$name' added. Token (shown once, send it privately):"
  printf '%s\n' "$token"
}

drop_client() {
  local tmp
  tmp="$(mktemp "$CLIENTS.XXXXXX")"
  grep -vE "^$1 " "$CLIENTS" > "$tmp" || true
  mv "$tmp" "$CLIENTS"
  render_clients_map
}

cmd_remove_client() {
  local name="${1:-}"
  valid_name "$name"
  [[ -f $CLIENTS ]] && grep -qE "^${name} " "$CLIENTS" || die "No client '$name'"
  drop_client "$name"
  reload_proxy || die "proxy reload failed; '$name' is removed from $CLIENTS but may still work until the proxy restarts"
  ok "Client '$name' removed"
}

case "${1:-}" in
  prepare)       cmd_prepare ;;
  up)            cmd_prepare
                 compose up -d --remove-orphans --wait --wait-timeout 60 \
                   || { compose logs --tail 50; die "compose up failed"; }
                 cmd_smoke ;;
  smoke)         cmd_smoke ;;
  add-client)    cmd_add_client "${2:-}" ;;
  remove-client) cmd_remove_client "${2:-}" ;;
  list-clients)  [[ -f $CLIENTS ]] && cut -d' ' -f1 "$CLIENTS" || true ;;
  down)          compose down ;;
  logs)          compose logs -f --tail 100 ;;
  ps)            compose ps ;;
  *)             sed -n '2,11p' "$0"; exit 1 ;;
esac
