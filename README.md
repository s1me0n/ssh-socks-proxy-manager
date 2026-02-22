# SSH SOCKS5 Proxy Manager

Android app built with Flutter for managing SSH SOCKS5 proxy tunnels.

## Features

- 🔒 **SSH Tunnel Management** — Add, edit, delete SSH server configurations
- 🚀 **One-tap Connect** — Start SOCKS5 proxy tunnels instantly
- 🔄 **Auto-restart** — Health checks every 30s with automatic reconnection
- 📡 **Network Change Handling** — Reconnects tunnels when network changes
- 🔍 **Port Scanner** — Scan all ports (1-65535) to discover external SOCKS proxies
- 🏗️ **Boot Persistence** — Auto-start tunnels on device boot
- 🎨 **Material 3 UI** — Modern dark theme with Material You design

## Architecture

```
lib/
├── main.dart                    # App entry point
├── models/
│   ├── server_config.dart       # Server configuration model
│   └── active_tunnel.dart       # Active tunnel state model
├── services/
│   └── proxy_service.dart       # Core SSH/SOCKS proxy service
└── screens/
    ├── home_screen.dart          # Bottom navigation host
    ├── servers_tab.dart          # Server list & management
    ├── active_tunnels_tab.dart   # Active tunnels overview
    └── server_form_screen.dart   # Add/edit server form
```

## Dependencies

- **dartssh2** — Pure Dart SSH2 client
- **shared_preferences** — Persistent storage for server configs
- **flutter_background_service** — Background service for tunnel persistence
- **connectivity_plus** — Network change detection
- **provider** — State management

## Getting Started

1. Clone the repository
2. Run `flutter pub get`
3. Run `flutter run` on an Android device/emulator

## Usage

1. **Add a server** — Tap the + button, enter SSH credentials and SOCKS port
2. **Connect** — Tap the play button to start the tunnel
3. **Configure apps** — Set your apps to use `127.0.0.1:<socks_port>` as SOCKS5 proxy
4. **Scan ports** — Use the search icon on Active tab to discover external proxies

## License

MIT
