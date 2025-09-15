## Qubetics dev dVPN Node Script

This repository contains helper scripts to install prerequisites, configure WireGuard, and manage a Qubetics dVPN node via systemd.

### What’s included
- `install-go.sh`: Installs a recent Go toolchain for building/running tooling if not present.
- `setup_wireguard.sh`: Installs WireGuard, generates/uses keys, and writes a minimal `/etc/wireguard/wg0.conf` with NAT rules.
- `start-node.sh`: All-in-one node manager with commands: `init`, `start`, `stop`, `restart`, `status`, `uninstall-wireguard`, `uninstall-service`.

Notes:
- The script writes a systemd unit `dvpn-node.service` that runs the node as the current user.

---

### Requirements
- Ubuntu 20.04/22.04/24.04 with `systemd` and `apt`
- Root privileges for installing packages and writing `/etc/wireguard`
- Internet connectivity

---

### 1) Install Go (first-time setup)

```bash
cd /dev-dvpn-node-script
 ./install-go.sh
source ~/.bashrc
source ~/.profile
```

This updates your shell profile so `go` is on your `PATH` in new sessions.

---

### 2) Install and Configure WireGuard
You must have a working WireGuard interface (`wg0`) before initializing the node.

#### Install via script (recommended)
```bash
sudo  ./setup_wireguard.sh
# or provide your own private key (base64):
sudo  ./setup_wireguard.sh --private-key "<YOUR_BASE64_PRIVATE_KEY>"
```

#### Uninstall wireguard via script
```bash
sudo  ./setup_wireguard.sh --uninstall
```
What the script does:
- Installs `wireguard` and `wireguard-tools`
- Generates or imports keys under `/etc/wireguard`
- Writes `/etc/wireguard/wg0.conf` with defaults:
  - Address: `10.8.0.1/24`
  - ListenPort: `51820`
  - NAT via iptables
- Shows your public key and basic usage tips

Start and enable WireGuard:
```bash
sudo systemctl enable --now wg-quick@wg0
sudo wg show
```


### 3) Initialize the dVPN node
`init` prepares the node home, downloads the correct binary for your Ubuntu version, creates config and keys, and sets your account.

```bash
./start-node.sh init
```

Behavior:
- Verifies WireGuard is installed (`wg`, `wg-quick`)
- Installs Go if missing by running `install-go.sh`
- Detects your Ubuntu version and downloads `qubetics-dvpnx` to your Go bin directory
- Creates `~/.qubetics-dvpnx`, asks for node name and account name
- Writes `config.toml` with default prices and timers
- Sets `from_name` to your chosen account in `config.toml`


---

### 4) Start the node as a systemd service
The `start` command writes/updates the systemd unit and enables it. Then start the service manually.

```bash
./start-node.sh start
sudo systemctl start dvpn-node.service
```

Check status and logs:
```bash
./start-node.sh status
# or directly
sudo systemctl status dvpn-node.service --no-pager | cat
journalctl -u dvpn-node.service -n 50 --no-pager | cat
```

Restart/stop:
```bash
./start-node.sh restart
./start-node.sh stop
```

Uninstall:
```bash
# Remove systemd unit and node data (~/.qubetics-dvpnx)
./start-node.sh uninstall-service

# Remove WireGuard packages and /etc/wireguard
./start-node.sh uninstall-wireguard
```

---

### How WireGuard settings sync into the node config
On `start`, the script reads `/etc/wireguard/wg0.conf` and updates the `[wireguard]` section of `~/.qubetics-dvpnx/config.toml` with:
- `ipv4_addr` -> `Address`
- `port` > `ListenPort`
- `private_key` > `PrivateKey`

Ensure your `wg0.conf` is correct before starting the node.

---

### Quickstart
```bash
cd /dev-dvpn-node-script

sudo bash ./setup_wireguard.sh

sudo systemctl enable --now wg-quick@wg0

./start-node.sh init

./start-node.sh start

sudo systemctl start dvpn-node.service

./start-node.sh status
```

---

### Troubleshooting
- If `dvpn-node.service` is enabled but not started, run: `sudo systemctl start dvpn-node.service`.
- If the node cannot read WireGuard values, verify `/etc/wireguard/wg0.conf` exists and contains `Address`, `ListenPort`, and `PrivateKey`.
- Make sure outbound UDP/51820 and your selected API port are not blocked by a firewall or cloud rules.
- After editing `config.toml`, re-run `./start-node.sh start` then `sudo systemctl restart dvpn-node.service`.


