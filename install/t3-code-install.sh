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
    DO_NOT_TRACK=1 \
    GH_TELEMETRY=false \
    CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1 \
    DISABLE_TELEMETRY=1 \
    DISABLE_ERROR_REPORTING=1 \
    DISABLE_FEEDBACK_COMMAND=1 \
    CLAUDE_CODE_DISABLE_FEEDBACK_SURVEY=1 \
    GROK_TELEMETRY_ENABLED=0 \
    GROK_TELEMETRY_TRACE_UPLOAD=0 \
    GROK_TELEMETRY_MIXPANEL_ENABLED=0 \
    GROK_EXTERNAL_OTEL=0 \
    "$@"
}

configure_codex_privacy() {
  local config_file=/root/.codex/config.toml

  mkdir -p /root/.codex
  if [[ -f "$config_file" ]]; then
    awk '
      function finish_section() {
        if (section == "analytics" && !key_seen) print "enabled = false"
        if (section == "otel" && !key_seen) print "exporter = \"none\""
        if (section == "history" && !key_seen) print "persistence = \"none\""
      }
      /^[[:space:]]*\[/ {
        finish_section()
        section = "other"
        key_seen = 0
        if ($0 ~ /^[[:space:]]*\[analytics\][[:space:]]*$/) {
          section = "analytics"
          analytics_seen = 1
        } else if ($0 ~ /^[[:space:]]*\[otel\][[:space:]]*$/) {
          section = "otel"
          otel_seen = 1
        } else if ($0 ~ /^[[:space:]]*\[history\][[:space:]]*$/) {
          section = "history"
          history_seen = 1
        }
        print
        next
      }
      section == "analytics" && $0 ~ /^[[:space:]]*enabled[[:space:]]*=/ {
        print "enabled = false"
        key_seen = 1
        next
      }
      section == "otel" && $0 ~ /^[[:space:]]*exporter[[:space:]]*=/ {
        print "exporter = \"none\""
        key_seen = 1
        next
      }
      section == "history" && $0 ~ /^[[:space:]]*persistence[[:space:]]*=/ {
        print "persistence = \"none\""
        key_seen = 1
        next
      }
      { print }
      END {
        finish_section()
        if (!analytics_seen) print "\n[analytics]\nenabled = false"
        if (!otel_seen) print "\n[otel]\nexporter = \"none\""
        if (!history_seen) print "\n[history]\npersistence = \"none\""
      }
    ' "$config_file" >"$config_file.tmp" && mv "$config_file.tmp" "$config_file" || return 1
  else
    cat <<'EOF' >"$config_file"
[analytics]
enabled = false

[otel]
exporter = "none"

[history]
persistence = "none"
EOF
  fi
  chmod 600 "$config_file"
}

configure_opencode_privacy() {
  mkdir -p /etc/opencode
  if [[ -f /etc/opencode/opencode.json ]]; then
    jq '. + {share: "disabled"}' /etc/opencode/opencode.json >/etc/opencode/opencode.json.tmp \
      && mv /etc/opencode/opencode.json.tmp /etc/opencode/opencode.json || return 1
  else
    cat <<'EOF' >/etc/opencode/opencode.json
{
  "$schema": "https://opencode.ai/config.json",
  "share": "disabled"
}
EOF
  fi
  chmod 644 /etc/opencode/opencode.json
}

configure_t3_privacy() {
  msg_info "Configuring Privacy Defaults"
  cat <<'EOF' >/etc/profile.d/t3-code-privacy.sh
# T3 Code privacy defaults. Provider training controls remain account-specific.
export DO_NOT_TRACK=1
export GH_TELEMETRY=false
export CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1
export DISABLE_TELEMETRY=1
export DISABLE_ERROR_REPORTING=1
export DISABLE_FEEDBACK_COMMAND=1
export CLAUDE_CODE_DISABLE_FEEDBACK_SURVEY=1
export GROK_TELEMETRY_ENABLED=0
export GROK_TELEMETRY_TRACE_UPLOAD=0
export GROK_TELEMETRY_MIXPANEL_ENABLED=0
export GROK_EXTERNAL_OTEL=0
EOF
  chmod 644 /etc/profile.d/t3-code-privacy.sh
  configure_codex_privacy
  configure_opencode_privacy
  msg_ok "Configured Privacy Defaults"
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

show_privacy_instructions() {
  stop_spinner
  echo
  echo -e "${INFO}${BOLD}${DGN}Provider Privacy Actions${CL}"
  echo
  echo -e "${TAB}${YW}Telemetry defaults are disabled for the T3 root runtime. Model training and retention remain provider account settings:${CL}"
  echo -e "${TAB}${BGN}OpenAI: disable 'Improve the model for everyone' in ChatGPT Data Controls.${CL}"
  echo -e "${TAB}${BGN}Anthropic: disable model improvement at https://claude.ai/settings/data-privacy-controls${CL}"
  echo -e "${TAB}${BGN}Grok: run /privacy in Grok Build and disable coding-data sharing/retention.${CL}"
  echo -e "${TAB}${BGN}OpenCode: public conversation sharing is disabled by this template; provider policy still applies.${CL}"
  echo -e "${TAB}${YW}GitLab CLI has no verified official telemetry opt-out setting; DO_NOT_TRACK is inherited as a best-effort convention.${CL}"
  msg_ok "Provider Privacy Instructions"
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
Environment=DO_NOT_TRACK=1
Environment=GH_TELEMETRY=false
Environment=CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1
Environment=DISABLE_TELEMETRY=1
Environment=DISABLE_ERROR_REPORTING=1
Environment=DISABLE_FEEDBACK_COMMAND=1
Environment=CLAUDE_CODE_DISABLE_FEEDBACK_SURVEY=1
Environment=GROK_TELEMETRY_ENABLED=0
Environment=GROK_TELEMETRY_TRACE_UPLOAD=0
Environment=GROK_TELEMETRY_MIXPANEL_ENABLED=0
Environment=GROK_EXTERNAL_OTEL=0
EOF
configure_t3_privacy
root_exec /usr/bin/systemctl --user daemon-reload
root_exec /usr/bin/systemctl --user restart t3code.service
if ! root_exec /usr/bin/systemctl --user is-active --quiet t3code.service; then
  msg_error "T3 Code service failed to start"
  exit 1
fi
msg_ok "Configured Network Access"

install_selected_providers
install_source_control_tools
if [[ -x /usr/bin/gh ]]; then
  root_exec /usr/bin/gh config set telemetry disabled
fi
if [[ -x /usr/bin/az ]]; then
  root_exec /usr/bin/az config set core.collect_telemetry=false core.survey_message=no
fi
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
show_privacy_instructions

motd_ssh
customize
cleanup_lxc
