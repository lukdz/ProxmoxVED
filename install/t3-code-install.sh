#!/usr/bin/env bash

# Copyright (c) 2021-2026 community-scripts ORG
# Author: lukdz
# License: MIT | https://github.com/community-scripts/ProxmoxVED/raw/main/LICENSE
# Source: https://t3.codes/ | Github: https://github.com/pingdotgg/t3code

source /dev/stdin <<<"$FUNCTIONS_FILE_PATH"
color
verb_ip6
catch_errors
setting_up_container
network_check
update_os

t3_data="/opt/t3-code_data"
var_t3_providers="${var_t3_providers:-codex,claude,grok,opencode}"
var_t3_providers="${var_t3_providers//[[:space:]]/}"
var_t3_version_control="${var_t3_version_control:-git}"
var_t3_version_control="${var_t3_version_control//[[:space:]]/}"
var_t3_source_control="${var_t3_source_control:-github,gitlab,azure}"
var_t3_source_control="${var_t3_source_control//[[:space:]]/}"

ensure_dependencies jq
install_packages_with_retry \
  build-essential \
  python3 \
  dbus \
  dbus-user-session \
  libpam-systemd

if [[ ",${var_t3_version_control,,}," == *,git,* ]]; then
  install_packages_with_retry git
fi

NODE_VERSION="24" setup_nodejs

msg_info "Preparing Root User Service"
$STD systemctl start systemd-logind.service
$STD loginctl enable-linger root
$STD systemctl start user-runtime-dir@0.service user@0.service
for _ in {1..30}; do
  [[ -S /run/user/0/bus ]] && break
  sleep 1
done
if [[ ! -S /run/user/0/bus ]]; then
  msg_error "The root user service bus is unavailable. Ensure systemd user services are supported by this LXC."
  exit 1
fi
msg_ok "Prepared Root User Service"

root_exec() {
  $STD env \
    HOME=/root \
    USER=root \
    LOGNAME=root \
    SHELL=/bin/bash \
    PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
    T3CODE_HOME="$t3_data" \
    XDG_RUNTIME_DIR=/run/user/0 \
    DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/0/bus \
    NPM_CONFIG_PREFIX=/usr/local \
    NPM_CONFIG_CACHE=/root/.cache/npm \
    "$@"
}

stop_legacy_t3_service() {
  if id t3 >/dev/null 2>&1; then
    runuser --user t3 -- env \
      XDG_RUNTIME_DIR="/run/user/$(id -u t3)" \
      DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$(id -u t3)/bus" \
      /usr/bin/systemctl --user stop t3code.service 2>/dev/null || true
  fi
}

if [[ -d /home/t3/.t3 && -d "$t3_data" ]]; then
  if [[ -z "$(find "$t3_data" -mindepth 1 -print -quit 2>/dev/null)" ]]; then
    msg_info "Migrating T3 Code Data"
    stop_legacy_t3_service
    rmdir "$t3_data"
    mv /home/t3/.t3 "$t3_data"
    msg_ok "Migrated T3 Code Data"
  else
    msg_error "Both legacy and current T3 Code data directories exist; migration was not performed."
    exit 1
  fi
elif [[ -d /home/t3/.t3 && ! -e "$t3_data" ]]; then
  msg_info "Migrating T3 Code Data"
  stop_legacy_t3_service
  mv /home/t3/.t3 "$t3_data"
  msg_ok "Migrated T3 Code Data"
fi
mkdir -p "$t3_data"
chown -R root:root "$t3_data"

fix_resource_monitor_permissions() {
  local monitor
  t3_resource_monitor_repaired=0
  for monitor in "$t3_data"/runtime/versions/*/node_modules/t3/dist/resource-monitor/linux-*/t3-resource-monitor; do
    [[ -f "$monitor" ]] || continue
    if [[ ! -x "$monitor" ]]; then
      chmod 755 "$monitor"
      t3_resource_monitor_repaired=1
    fi
  done
}

provider_selected() {
  local provider="${1,,}"
  local selected=",${var_t3_providers,,},"
  [[ "$selected" == *",${provider},"* ]]
}

install_npm_provider() {
  local label="$1"
  local package="$2"
  msg_info "Installing ${label}"
  root_exec /usr/bin/npm install --global --prefix /usr/local \
    --allow-scripts="$package" "${package}@latest"
  msg_ok "Installed ${label}"
}

install_selected_providers() {
  t3_providers_installed=0
  [[ -n "${var_t3_providers:-}" && "${var_t3_providers,,}" != "none" ]] || return 0

  if provider_selected codex; then
    install_npm_provider "Codex CLI" "@openai/codex"
    t3_providers_installed=1
  fi
  if provider_selected claude; then
    setup_deb822_repo "claude-code" \
      "https://downloads.claude.ai/keys/claude-code.asc" \
      "https://downloads.claude.ai/claude-code/apt/stable" \
      "stable" "main"
    install_packages_with_retry claude-code
    t3_providers_installed=1
  fi
  if provider_selected grok; then
    install_npm_provider "Grok Build CLI" "@xai-official/grok"
    t3_providers_installed=1
  fi
  if provider_selected opencode; then
    install_npm_provider "OpenCode CLI" "opencode-ai"
    t3_providers_installed=1
  fi
}

source_control_selected() {
  local provider="${1,,}"
  local selected=",${var_t3_source_control,,},"
  [[ "$selected" == *",${provider},"* ]]
}

install_source_control_tools() {
  t3_source_control_configured=0
  [[ -n "${var_t3_source_control:-}" && "${var_t3_source_control,,}" != "none" ]] || return 0

  if source_control_selected github; then
    setup_deb822_repo "github-cli" \
      "https://cli.github.com/packages/githubcli-archive-keyring.gpg" \
      "https://cli.github.com/packages" \
      "stable" "main" "$(dpkg --print-architecture)"
    install_packages_with_retry gh
    t3_source_control_configured=1
  fi
  if source_control_selected gitlab; then
    fetch_and_deploy_gl_release "glab" "gitlab-org/cli" "binary"
    t3_source_control_configured=1
  fi
  if source_control_selected azure; then
    setup_deb822_repo "azure-cli" \
      "https://packages.microsoft.com/keys/microsoft.asc" \
      "https://packages.microsoft.com/repos/azure-cli/" \
      "bookworm" "main" "$(dpkg --print-architecture)"
    install_packages_with_retry azure-cli
    msg_info "Installing Azure DevOps extension"
    root_exec /usr/bin/az extension add --name azure-devops
    msg_ok "Installed Azure DevOps extension"
    t3_source_control_configured=1
  fi
}

show_provider_login_commands() {
  [[ "${t3_providers_installed:-0}" -eq 1 ]] || return 0

  stop_spinner
  echo
  echo -e "${INFO}${BOLD}${DGN}Provider Authentication${CL}"
  echo
  echo -e "${TAB}${YW}Selected provider CLIs are installed but not authenticated. Run these commands from the Proxmox host:${CL}"
  echo -e "${TAB}${YW}After authentication, enable Grok and OpenCode in T3 Code Settings if you selected them.${CL}"
  echo -e "${TAB}${YW}Authentication commands may open a browser or require terminal input.${CL}"
  provider_selected codex && echo -e "${TAB}${BGN}pct exec ${CTID} -- codex login${CL}"
  provider_selected claude && echo -e "${TAB}${BGN}pct exec ${CTID} -- claude auth login${CL}"
  provider_selected grok && echo -e "${TAB}${BGN}pct exec ${CTID} -- grok login${CL}"
  provider_selected opencode && echo -e "${TAB}${BGN}pct exec ${CTID} -- opencode auth login${CL}"
  msg_ok "Provider Authentication Instructions"
}

show_source_control_login_commands() {
  [[ "${t3_source_control_configured:-0}" -eq 1 ]] || return 0

  stop_spinner
  echo
  echo -e "${INFO}${BOLD}${DGN}Source Control Authentication${CL}"
  echo
  echo -e "${TAB}${YW}Selected source-control CLIs are installed but not authenticated. Run these commands from the Proxmox host:${CL}"
  echo -e "${TAB}${YW}Authentication is performed as root inside the container and is never done automatically.${CL}"
  source_control_selected github && echo -e "${TAB}${BGN}pct exec ${CTID} -- gh auth login${CL}"
  source_control_selected gitlab && echo -e "${TAB}${BGN}pct exec ${CTID} -- glab auth login${CL}"
  source_control_selected azure && echo -e "${TAB}${BGN}pct exec ${CTID} -- az login${CL}"
  msg_ok "Source Control Authentication Instructions"
}

finish_t3_service_setup() {
  local expected_version="${1:-}"
  local installed_version

  $STD loginctl enable-linger root
  if [[ ! -f /root/.config/systemd/user/t3code.service ||
    ! -f "$t3_data/runtime/service-launcher.mjs" ||
    ! -f "$t3_data/runtime/service-state.json" ]]; then
    return 1
  fi

  installed_version=$(jq -r '.activeVersion // empty' "$t3_data/runtime/service-state.json" 2>/dev/null || true)
  [[ "$installed_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 1
  [[ -z "$expected_version" || "$installed_version" == "$expected_version" ]] || return 1
  [[ -f "$t3_data/runtime/versions/${installed_version}/node_modules/t3/dist/bin.mjs" ]] || return 1
  [[ -f "$t3_data/runtime/versions/${installed_version}/.install-complete" ]] || return 1

  root_exec /usr/bin/systemctl --user daemon-reload
  root_exec /usr/bin/systemctl --user enable t3code.service
}

var_t3_providers="${var_t3_providers//[[:space:]]/}"
var_t3_source_control="${var_t3_source_control//[[:space:]]/}"

msg_info "Installing T3 Code"
if ! root_exec /usr/bin/npx --yes t3@latest service install --base-dir "$t3_data"; then
  msg_warn "T3 could not enable lingering for root; completing service setup as root."
  if ! finish_t3_service_setup; then
    msg_error "T3 Code service installation failed"
    exit 1
  fi
fi
msg_ok "Installed T3 Code"
fix_resource_monitor_permissions
if [[ "$t3_resource_monitor_repaired" -eq 1 ]]; then
  msg_ok "Repaired T3 resource monitor permissions"
fi

msg_info "Configuring Network Access"
mkdir -p /root/.config/systemd/user/t3code.service.d
cat <<EOF >/root/.config/systemd/user/t3code.service.d/10-network.conf
[Service]
Environment=HOME=/root
Environment=PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
Environment=NPM_CONFIG_PREFIX=/usr/local
Environment=T3CODE_HOME=${t3_data}
Environment=T3CODE_HOST=0.0.0.0
Environment=T3CODE_PORT=3773
EOF
root_exec /usr/bin/systemctl --user daemon-reload
root_exec /usr/bin/systemctl --user restart t3code.service
if ! root_exec /usr/bin/systemctl --user is-active --quiet t3code.service; then
  msg_error "T3 Code service failed to start"
  exit 1
fi
msg_ok "Configured Network Access"

install_selected_providers
install_source_control_tools
if [[ "${t3_providers_installed:-0}" -eq 1 || "${t3_source_control_configured:-0}" -eq 1 ]]; then
  msg_info "Refreshing T3 Integration Status"
  root_exec /usr/bin/systemctl --user restart t3code.service
  msg_ok "Refreshed T3 Integration Status"
fi

t3_version=$(jq -r '.activeVersion // empty' "$t3_data/runtime/service-state.json" 2>/dev/null || true)
if [[ ! "$t3_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  msg_error "Unable to determine the installed T3 Code version."
  exit 1
fi
cat <<EOF >/root/.t3-code
${t3_version}
EOF

msg_info "Generating Pairing URL"
t3_pair_output=""
for _ in {1..30}; do
  if t3_pair_output=$(STD="" root_exec /usr/bin/npx --yes "t3@${t3_version}" pair --base-dir "$t3_data" --ttl 1h 2>/dev/null); then
    stop_spinner
    clear_line
    echo -e "${INFO}${YW}Generating Pairing URL${CL}"
    printf '%s\n' "$t3_pair_output"
    break
  fi
  sleep 1
done
if [[ -z "$t3_pair_output" ]]; then
  msg_warn "Could not generate a pairing URL automatically. Run this inside the container as root: npx --yes t3@${t3_version} pair --base-dir ${t3_data} --ttl 1h"
fi

show_provider_login_commands
show_source_control_login_commands

motd_ssh
customize
cleanup_lxc
