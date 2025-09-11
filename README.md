
sudo apt install wireguard


sudo rm -rf /etc/systemd/system/dvpn-node.service
sudo rm -rf /home/user/.qubetics-dvpnx           



 sudo nano /etc/systemd/system/dvpn-node.service

sudo systemctl daemon-reload
sudo systemctl restart dvpn-node.service 
journalctl -u dvpn-node.service -f

curl -k https://112.196.81.250:18133


API_PORT=18133



sudo setcap cap_net_admin+ep /path/to/your-binary

================= wireguadr uninstall


# Stop any running WireGuard interfaces
sudo wg-quick down wg0   # repeat for other interfaces if any

# Remove WireGuard packages
sudo apt purge wireguard wireguard-tools -y

# Remove dependencies no longer needed
sudo apt autoremove -y

# Delete configuration directory
sudo rm -rf /etc/wireguard
