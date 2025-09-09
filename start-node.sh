#!/usr/bin/env bash

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

set -Eeou pipefail
NODE_DIR="${HOME}/.qubetics-dvpnx"
BINARY="${BINARY:-qubetics-dvpnx}"  # Default binary name; override by setting $BINARY
CONTAINER_NAME=qubetics-node  # For legacy cmd compatibility
API_PORT=18133
SERVICE_PORT=21529
PUBLIC_IP=$(curl -fsSL https://ifconfig.me)

# --- Binary Download Logic ---
# Detect Ubuntu version
UBUNTU_VERSION=$(lsb_release -rs | cut -d. -f1)

# Set binary download URL (update this if your release URL pattern is different)
BINARY_URL="https://github.com/Qubetics/dvpn-node-script/releases/latest/download/${BINARY}-ubuntu${UBUNTU_VERSION}"


# Target directory for binary
INSTALL_PATH="/usr/local/bin/"
mkdir -p "$INSTALL_PATH"

# Download and move binary
echo "Downloading binary for Ubuntu $UBUNTU_VERSION: $BINARY_URL"
curl -L "$BINARY_URL" -o "/tmp/${BINARY}"
chmod +x "/tmp/${BINARY}"
mv "/tmp/${BINARY}" "$INSTALL_PATH${BINARY}"
echo "Binary moved to $INSTALL_PATH${BINARY}"

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
    --rpc.addrs "http://111.119.253.129:26657" \
    --rpc.chain-id "qubetics_9009-1" \
    --with-tls \
    --keyring.backend "test" \
    --keyring.name "qubetics"

 

  echo "Initializing keys..."
  read -p "Enter the account name: " ACCOUNT_NAME
  if [[ "${ACCOUNT_NAME}" == "" ]]; then
    ACCOUNT_NAME="main"
  fi
  "${BINARY}" keys add "${ACCOUNT_NAME}" \
    --home "${NODE_DIR}" \
    --keyring.backend "test" \
    --keyring.name "qubetics"

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
  echo "${BINARY} start --home ${NODE_DIR} --keyring.backend test --node.remote-addrs ${NODE_REMOTE_URL}"
  
  # Start the node
  "${BINARY}" start \
    --home "${NODE_DIR}" \
    --keyring.backend "test"
    --log.level "debug" 

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
