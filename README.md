# MT5 Docker Image

Docker image for running MetaTrader 5 Expert Advisors headlessly on Linux.

## Features

- Runs MT5 via Wine on Debian Bookworm
- KasmVNC web-based display for browser access
- Docker secrets for secure credential management
- Auto-compilation of `.mq5` and `.c` source files
- Automatic EA startup on container launch
- Graceful shutdown handling

## Quick Start

1. Create an accounts file:
   ```sh
   cp accounts.txt.example accounts.txt
   # Edit accounts.txt with your credentials
   ```

2. Place your EA files in the `bots/` directory:
   ```sh
   cp MyExpert.mq5 bots/
   # or: cp MyExpert.ex5 bots/
   ```

3. Run:
   ```sh
   docker compose up -d
   ```

   The image is pre-built by CI and pulled from Docker Hub automatically.

4. View logs:
   ```sh
   docker compose logs -f mt5
   ```

5. Access the web UI at `http://localhost:3000`

## Bot File Types

| Type | Description |
|------|-------------|
| `.ex5` | Pre-compiled Expert Advisors (used directly) |
| `.mq5` | MQL5 source files (compiled automatically at startup) |
| `.c` | MQL5 source files with `.c` extension (renamed to `.mq5` and compiled) |

## Configuration

### Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `DISPLAY` | `:1` | X11 display |
| `WINEDEBUG` | `-all` | Wine debug output |
| `WINEPREFIX` | `/config/.wine` | Wine prefix directory |

### Secrets

| Secret | Path | Format |
|--------|------|--------|
| `accounts` | `/run/secrets/accounts` | See formats below |

#### Credential Formats

**Single-line format** (login:password:server):
```
12345678:yourpassword:YourBroker-Server
```

**Multi-line format**:
```
AccountMT5:
12345678
yourpassword
Server YourBroker-Server
```

### Volumes

| Mount | Description |
|-------|-------------|
| `./bots` | Directory containing EA files (mounted read-only) |
| `mt5data` | Named volume for MT5 data persistence |

## Security Notes

- **seccomp=unconfined**: Required for Wine to handle Windows syscalls (e.g., `NtRaiseHardError`)
- **PUID=0/PGID=0**: Container runs as root for Wine/MT5 path compatibility
- Credentials are passed via Docker secrets, never environment variables
- The `accounts.txt` file is excluded from version control via `.gitignore`

## License

[AGPL v3.0](LICENSE).<br>
Copyright &copy; 2026 [Hieu Pham](https://github.com/hieupth). All rights reserved.
