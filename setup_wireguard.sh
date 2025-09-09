#!/bin/bash
set -e  # Exit on error

# Configuration
WG_DIR="/etc/wireguard"
WG_CONF="$WG_DIR/wg0.conf"
WG_INTERFACE="wg0"
WG_NETWORK="10.8.0.1/24"
WG_PORT="51820"
PRIVATE_KEY=""

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Function to check if running as root
check_root() {
    if [ "$(id -u)" -ne 0 ]; then
        echo -e "${RED}Error: This script must be run as root${NC}" >&2
        exit 1
    fi
}

# Function to handle keys
handle_keys() {
    echo -e "${YELLOW}Setting up WireGuard keys...${NC}"    
    # Create directory with secure permissions
    mkdir -p "$WG_DIR"
    chmod 700 "$WG_DIR"
    
    # Use provided private key or generate new one
    if [ -n "$PRIVATE_KEY" ]; then
        echo -e "${YELLOW}Using provided private key${NC}"
        echo "$PRIVATE_KEY" > "$WG_DIR/private.key"
        chmod 600 "$WG_DIR/private.key"
        wg pubkey < "$WG_DIR/private.key" > "$WG_DIR/public.key"
    else
        echo -e "${YELLOW}Generating new private key${NC}"
        umask 077
        wg genkey | tee "$WG_DIR/private.key" | wg pubkey > "$WG_DIR/public.key"
        chmod 600 "$WG_DIR/private.key"
    fi
    
    # Set public key permissions
    chmod 644 "$WG_DIR/public.key"
}

# Function to create WireGuard config
create_wg_config() {
    echo -e "${YELLOW}Creating WireGuard configuration...${NC}"
    
    # Check if config already exists
    if [ -f "$WG_CONF" ]; then
        echo -e "${YELLOW}WireGuard configuration already exists, backing up to $WG_CONF.bak${NC}"
        cp "$WG_CONF" "${WG_CONF}.bak"
    fi
    
    # Get the primary network interface
    PRIMARY_IFACE=$(ip route | grep '^default' | awk '{print $5}' | head -n 1)
    
    # Create new config
    cat > "$WG_CONF" <<EOL
[Interface]
PrivateKey = $(cat "$WG_DIR/private.key")
Address = $WG_NETWORK
ListenPort = $WG_PORT
SaveConfig = true
PostUp = iptables -A FORWARD -i $WG_INTERFACE -j ACCEPT; iptables -t nat -A POSTROUTING -o $PRIMARY_IFACE -j MASQUERADE
PostDown = iptables -D FORWARD -i $WG_INTERFACE -j ACCEPT; iptables -t nat -D POSTROUTING -o $PRIMARY_IFACE -j MASQUERADE
EOL

    chmod 600 "$WG_CONF"
}

# Function to display setup information
show_setup_info() {
    echo -e "\n${GREEN}WireGuard setup complete!${NC}"
    echo -e "Public key: ${YELLOW}$(cat "$WG_DIR/public.key")${NC}"
    echo -e "Interface: ${WG_INTERFACE}"
    echo -e "Network: ${WG_NETWORK}"
    echo -e "Port: ${WG_PORT}"
    echo -e "\nTo start WireGuard: ${YELLOW}systemctl start wg-quick@$WG_INTERFACE${NC}"
    echo -e "To enable on boot: ${YELLOW}systemctl enable wg-quick@$WG_INTERFACE${NC}"
}

# Show usage information
show_usage() {
    echo "Usage: $0 [--private-key PRIVATE_KEY]"
    echo "Options:"
    echo "  --private-key PRIVATE_KEY  Use the provided WireGuard private key"
    echo "  -h, --help                Show this help message"
    exit 1
}

# Parse command line arguments
parse_arguments() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            --private-key)
                PRIVATE_KEY="$2"
                shift 2
                ;;
            -h|--help)
                show_usage
                ;;
            *)
                echo -e "${RED}Error: Unknown option $1${NC}" >&2
                show_usage
                ;;
        esac
    done
}

# Main execution
main() {
    parse_arguments "$@"
    check_root
    handle_keys
    create_wg_config
    show_setup_info
}

main "$@"