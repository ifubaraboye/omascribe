# Windscribe bar widget for Omarchy

Connect, disconnect, and pick a server for [Windscribe](https://www.windscribe.com/) straight from the [Omarchy](https://github.com/artemisa81/omarchy) bar.

Built for `oribi.windscribe`, adapted from the [omarchy IVPN plugin](https://github.com/artemisa81/omarchy-ivpn-plugin).

## Features

- Toggle the tunnel from the bar icon (left click), refresh (right click), or via IPC.
- Searchable server dropdown with 200+ locations, Pro/Free labels, and a **Free servers only** filter.
- World map showing your home location and the tunnel exit, with per-server coordinates from the Windscribe server-list API.
- Live status: protocol, VPN IP, uptime, and data usage.
- Firewall on/off toggle (with a warning when enabled while disconnected).
- WireGuard / UDP / TCP / Stealth protocol selection.
- A single serialized `windscribe-cli` worker behind a FIFO queue — Windscribe only allows one CLI instance, and this never collides with itself, so connects stay connected.

## Install

```sh
# clone the plugin into your omarchy plugins folder
git clone https://github.com/ifubaraboye/omascribe.git \
  ~/.config/omarchy/plugins/oribi.windscribe

# validate and enable it
omarchy plugin validate ~/.config/omarchy/plugins/oribi.windscribe
omarchy plugin enable oribi.windscribe
```

Requires the Windscribe CLI (`windscribe-cli`) and daemon installed and logged in.

## Usage

Open the widget from the bar icon. The power switch connects/disconnects, the dropdown picks a server, and the Firewall toggle arms Windscribe's kill-switch.

### IPC

```sh
omarchy-shell oribi.windscribe status        # e.g. "Connected"
omarchy-shell oribi.windscribe connect       # connect to the selected server
omarchy-shell oribi.windscribe disconnect
omarchy-shell oribi.windscribe toggle
omarchy-shell oribi.windscribe firewall on|off
omarchy-shell oribi.windscribe serverStats   # e.g. "free: 25 / pro: 176 / total: 202"
```

## Configuration

| Setting             | Type    | Default     | Description                                              |
| ------------------- | ------- | ----------- | -------------------------------------------------------- |
| `refreshIntervalSec`| integer | `5`         | Seconds between `windscribe-cli status` polls (2–60).    |
| `protocol`          | enum    | `WireGuard` | WireGuard, UDP, TCP, or Stealth.                         |
| `publicIpLookup`    | boolean | `false`     | Ask ipinfo.io for your public IP to plot home on the map.|

## Notes

- The server list comes from `https://assets.windscribe.com/serverlist/ikev2/1/1` (cached for 12h in `~/.config/omarchy/windscribe-servers.json`); the free/Pro flags are merged from `windscribe-cli locations`.
- The server-list API labels every node as Pro, so free locations are detected from the CLI and applied over the API list.
- `connect` resolves a selected location to its unique **nickname** (e.g. `Comfort Zone`), because the CLI matches nicknames/cities/regions, not the full `Region - City - Nickname` string.

## License

MIT