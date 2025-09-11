#!/usr/bin/env bash

set -Eeou pipefail

NODE_DIR="${HOME}/.qubetics-dvpnx"
BINARY="${BINARY:-qubetics-dvpnx}"  # Default binary name; override by setting $BINARY
CONTAINER_NAME=qubetics-node 
API_PORT=18133
SERVICE_PORT=21529
PUBLIC_IP=$(curl -fsSL https://ifconfig.me)
CHAIN_RPC="http://111.119.253.129:26657"
CHAIN_ID="qubetics_9003-1"
KEYRING_BACKEND="test"
KEYRING_NAME="qubetics"
LOG_LEVEL="debug"
WG_CONF="/etc/wireguard/wg0.conf"

function cmd_help {
  echo "Usage: ${0} [COMMAND]"
  echo ""
  echo "Commands:"
  echo "  init       Initialize configuration and keys"
  echo "  start      Start the node"
  echo "  stop       Stop the node process (if backgrounded)"
  echo "  restart    Restart the node"
  echo "  status     Show node logs (if running)"
  echo "  help       Print this help message"
}







function cmd_init {
  # --- Go Installation Check ---
if ! command -v go &> /dev/null; then
  echo "Go not found. Installing Go..."
  bash "$(dirname "$0")/install-go.sh"
  source ~/.profile
  source ~/.bashrc
  echo "Go installed and environment updated."
else
  echo "Go is already installed. Skipping installation."
fi

# --- Binary Download Logic ---
# Detect Ubuntu version
UBUNTU_VERSION=$(lsb_release -rs)
# Set binary download URL (update this if your release URL pattern is different)
BINARY_URL="https://github.com/Qubetics/dvpn-node-script/releases/download/ubuntu${UBUNTU_VERSION}/${BINARY}"
echo $BINARY_URL


# curl -k https://101.44.160.159:18133/
# Target directory for binary
GOLANGPATH=$(which go)
INSTALL_PATH="$(dirname "$GOLANGPATH")"
# Remove trailing '/go' if present
if [[ "$INSTALL_PATH" == */go ]]; then
  INSTALL_PATH="${INSTALL_PATH%/go}"
fi
echo "INSTALL PATH OF THE BINARY:" $INSTALL_PATH/


# Download and move binary
echo "Downloading binary for Ubuntu $UBUNTU_VERSION: $BINARY_URL"
curl -L "$BINARY_URL" -o "/tmp/${BINARY}"
chmod +x "/tmp/${BINARY}"
sudo mv "/tmp/${BINARY}" "$INSTALL_PATH/${BINARY}"
echo "Binary moved to $INSTALL_PATH/${BINARY}"


  mkdir -p "${NODE_DIR}"
  MONIKER="node-$(openssl rand -hex 4)"
  
  read -p "Enter the Node name: " NODE_NAME
  if [[ "${NODE_NAME}" == "" ]]; then
    MONIKER=$MONIKER
  fi

  echo "Detected public IP: ${PUBLIC_IP}"
  echo "Generated moniker: ${MONIKER}"
  echo "Selected API port: ${API_PORT}"
  echo "Selected service port: ${SERVICE_PORT}"
  echo ""

  read -p "Enter node type [v2ray|wireguard] (default: wireguard): " NODE_TYPE
  NODE_TYPE="${NODE_TYPE:-wireguard}"

  echo "Initializing config..."
  "${BINARY}" init \
    --force \
    --home "${NODE_DIR}" \
    --node.moniker "${MONIKER}" \
    --node.api-port "${API_PORT}" \
    --node.remote-addrs "${PUBLIC_IP}" \
    --node.gigabyte-prices "200;200;tics" \
    --node.hourly-prices "20;20;tics" \
    --node.type "${NODE_TYPE}" \
    --rpc.addrs "${CHAIN_RPC}" \
    --rpc.chain-id "${CHAIN_ID}" \
    --with-tls \
    --keyring.backend "${KEYRING_BACKEND}" \
    --keyring.name "${KEYRING_NAME}"

 

  echo "Initializing keys..."
  read -p "Enter the account name: " ACCOUNT_NAME
  if [[ "${ACCOUNT_NAME}" == "" ]]; then
    ACCOUNT_NAME="main"
  fi
  "${BINARY}" keys add "${ACCOUNT_NAME}" \
    --home "${NODE_DIR}" \
    --keyring.backend "${KEYRING_BACKEND}" \
    --keyring.name "${KEYRING_NAME}"

  # Update from_name in config.toml with the account name
  if [[ -f "${NODE_DIR}/config.toml" ]]; then
    # Use sed to update the from_name field
    if sed -i "s/^from_name = .*/from_name = \"${ACCOUNT_NAME}\"/" "${NODE_DIR}/config.toml"; then
      echo "Updated from_name to '${ACCOUNT_NAME}' in config.toml"
    else
      echo "Warning: Failed to update from_name in config.toml"
    fi
  fi

  echo "====================================================================================="
  echo "  Please make sure that the key has balance added to it before running START command"
  echo "====================================================================================="
}


function cmd_start {
    #  wg-quick down wg0
    # Extract WireGuard config values using sudo
if sudo test -f "$WG_CONF"; then
  WG_ADDRESS=$(sudo grep -m1 '^Address' "$WG_CONF" | sed -E 's/.*[:=][[:space:]]*//')
  WG_LISTENPORT=$(sudo grep -m1 '^ListenPort' "$WG_CONF" | awk -F '=' '{print $2}')
  WG_PRIVATEKEY=$(sudo grep -m1 '^PrivateKey' "$WG_CONF" | awk -F '=' '{print $2}')
  PRIVATE_KEY=$(echo "$WG_PRIVATEKEY" | xargs)
  if [[ "$PRIVATE_KEY" != *= ]]; then
    PRIVATE_KEY="${PRIVATE_KEY}="
  fi
  echo "WireGuard Config:"
  echo "- Address: $WG_ADDRESS"
  echo "- ListenPort: $WG_LISTENPORT"
  echo "- PrivateKey: $PRIVATE_KEY"
else
  echo "WireGuard config not found at $WG_CONF"
fi

# Update ~/.qubetics-dvpnx/config.toml [wireguard] section with values from wg0.conf
CONFIG_TOML="${NODE_DIR}/config.toml"
if [[ -f "$CONFIG_TOML" ]]; then
  # Extract first IPv4 address from WG_ADDRESS (Address can be comma-separated and include IPv6)
  if [[ -n "$WG_ADDRESS" && -n "$WG_LISTENPORT" && -n "$WG_PRIVATEKEY" ]]; then
    echo "Updating $CONFIG_TOML [wireguard] ipv4_addr, port, private_key"
    cp "$CONFIG_TOML" "${CONFIG_TOML}.bak.$(date +%s)"
    # Replace only inside [wireguard] section
    sed -i -E '/^\[wireguard\]/,/^\[/ {
      s|^ipv4_addr = .*|ipv4_addr = "'"${WG_ADDRESS//&/\\&}"'"|
      s|^port = .*|port = "'"${WG_LISTENPORT//&/\\&}"'"|
      s|^private_key = .*|private_key = "'"${PRIVATE_KEY//&/\\&}"'"|
    }' "$CONFIG_TOML"
  else
    echo "WireGuard values missing; skipping config.toml update"
  fi
else
  echo "Config file not found at $CONFIG_TOML"
fi
    echo "=== Starting Node ==="
    # Generate random ports
    mapfile -t PORTS < <(shuf -i 1024-65535 -n 2)
    # Format the URL with a scheme and host that will be properly parsed
    # NODE_REMOTE_URL="https://${PUBLIC_IP}:${SERVICE_PORT}"
    echo "=== Starting Node ==="
    echo "Config file: ${NODE_DIR}/config.toml"
  
  # Check if config file exists
  if [[ ! -f "${NODE_DIR}/config.toml" ]]; then
    echo "Error: Config file not found at ${NODE_DIR}/config.toml"
    exit 1
  fi
  
  # Get API port from config
  API_PORT=$(grep '^api_port = ' "${NODE_DIR}/config.toml" | cut -d'"' -f2)
  
  # Get node type from config
  NODE_TYPE=$(grep '^type = ' "${NODE_DIR}/config.toml" | cut -d'"' -f2)

  # Remove any existing https:// from the IP address
  CLEAN_IP=${PUBLIC_IP#https://}
  CLEAN_IP=${CLEAN_IP#http://}
  echo "Clean IP: ${CLEAN_IP}"
  
  # Format the URL properly
  NODE_REMOTE_URL="${CLEAN_IP}"
  
  # Debug output
  echo "Parsed Configuration:"
  echo "- API Port: ${API_PORT:-Not found}"
  echo "- Node Type: ${NODE_TYPE:-Not found}"
  echo "- Node Remote URL: ${NODE_REMOTE_URL:-Not found}"
  
  if [[ -z "${API_PORT}" || -z "${NODE_TYPE}" ]]; then
    echo "Error: Could not read required configuration. Check config.toml format."
    exit 1
  fi

  
  echo "Starting node with command:"
  echo "${BINARY} start --home ${NODE_DIR} --keyring.backend ${KEYRING_BACKEND} --node.remote-addrs ${NODE_REMOTE_URL}"
  
  # Start the node
  # "${BINARY}" start \
  #   --home "${NODE_DIR}" \
  #   --keyring.backend "${KEYRING_BACKEND}"
  #   --log.level "${LOG_LEVEL}" 
#   sudo systemctl start wg-quick@wg0
# echo "Starting node:"
# #========================================================================================================================================================
# sudo su -c  "echo '[Unit]
# Description=Qubetics dVPN Node
# Wants=network-online.target
# After=network-online.target
# [Service]
# User=$(whoami)
# Group=$(whoami)
# Type=simple
# ExecStart=/${HOME}/.go/bin/qubetics-dvpnx start --home $NODE_DIR --keyring.backend test
# Restart=always
# RestartSec=5
# LimitNOFILE=65536
# Environment="DAEMON_NAME=$BINARY"
# Environment="DAEMON_HOME="$NODE_DIR""
# Environment="DAEMON_ALLOW_DOWNLOAD_BINARIES=false"
# Environment="DAEMON_RESTART_AFTER_UPGRADE=true"
# Environment="DAEMON_LOG_BUFFER_SIZE=512"
# Environment="UNSAFE_SKIP_BACKUP=false"
# [Install]
# WantedBy=multi-user.target'> /etc/systemd/system/dvpn-node.service"

# sudo systemctl daemon-reload
# sudo systemctl enable dvpn-node.service 
# sudo systemctl start dvpn-node.service 

# # Wait a few minutes before fetching node address
# echo "Waiting 30 seconds for node to initialize..."
# sleep 30
# NODE_ADDR=$(curl -sk https://$PUBLIC_IP:$API_PORT | jq -r '.result.addr')
# NODE_ADDR=$(curl -sk https://125.21.216.158:18133 | jq -r '.result.addr')
# echo "Node address: $NODE_ADDR"
}

function cmd_status {
  echo "Last 20 log lines (if started in background with redirection):"
  tail -n 20 "${NODE_DIR}/node.log" 2>/dev/null || echo "No log file found."
}

function cmd_stop {
  pkill -f "${BINARY} start --home ${NODE_DIR}" || echo "No running node process found."
}

function cmd_restart {
  cmd_stop
  sleep 1
  cmd_start
}

# Dispatch commands
v="${1:-help}"
shift || true
case "${v}" in
  "init") cmd_init ;;
  "start") cmd_start ;;
  "stop") cmd_stop ;;
  "restart") cmd_restart ;;
  "status") cmd_status ;;
  "help" | *) cmd_help ;;
esac


