#!/bin/bash
set -euo pipefail

export DISPLAY=${DISPLAY:-:1}
export WINEPREFIX=/opt/mt5-seed/.wine

MT5_DIR="${WINEPREFIX}/drive_c/Program Files/MetaTrader 5"
TERMINAL="$MT5_DIR/terminal64.exe"
EXPERTS_DIR="$MT5_DIR/MQL5/Experts"

# --- Helper: wait for wineserver with timeout ---
wine_wait() {
    local timeout=${1:-120}
    wineserver -w &
    local WAIT_PID=$!
    local elapsed=0
    while [ $elapsed -lt "$timeout" ]; do
        if ! kill -0 $WAIT_PID 2>/dev/null; then
            return 0
        fi
        sleep 2
        elapsed=$((elapsed + 2))
    done
    echo "[install] WARNING: wineserver wait timed out after ${timeout}s"
    kill $WAIT_PID 2>/dev/null || true
    wineserver -k 2>/dev/null || true
    sleep 2
}

# --- Initialize Wine prefix ---
echo "[install] Initializing Wine prefix..."
mkdir -p "$WINEPREFIX"
WINEDLLOVERRIDES=mscoree=d,mshtml=d wineboot --init
echo "[install] Wine prefix created, waiting for services to finish..."
wine_wait 300
echo "[install] Wine prefix initialized"

# Install Wine Mono
echo "[install] Downloading Wine Mono 10.3.0..."
wget -q -O /tmp/mono.msi \
    "https://dl.winehq.org/wine/wine-mono/10.3.0/wine-mono-10.3.0-x86.msi"
echo "[install] Installing Wine Mono..."
WINEDLLOVERRIDES=mscoree=d wine msiexec /i /tmp/mono.msi /qn
wine_wait 120
rm -f /tmp/mono.msi
echo "[install] Wine Mono installed"

# Set Windows 10 mode
echo "[install] Setting Windows 10 mode..."
wine reg add "HKEY_CURRENT_USER\\Software\\Wine" /v Version /t REG_SZ /d "win10" /f
wine_wait 30
echo "[install] Windows 10 mode set"

# --- Install MT5 ---
echo "[install] Downloading MetaTrader 5 installer..."
wget -q -O "$WINEPREFIX/drive_c/mt5setup.exe" \
    https://download.mql5.com/cdn/web/metaquotes.software.corp/mt5/mt5setup.exe

echo "[install] Installing MetaTrader 5..."
wine "$WINEPREFIX/drive_c/mt5setup.exe" /auto &
INSTALL_PID=$!
TIMEOUT=300
ELAPSED=0
while [ ! -f "$TERMINAL" ] && [ $ELAPSED -lt $TIMEOUT ]; do
    sleep 5
    ELAPSED=$((ELAPSED + 5))
    if [ $((ELAPSED % 30)) -eq 0 ]; then
        echo "[install] Still installing MT5... (${ELAPSED}s)"
    fi
done
if [ ! -f "$TERMINAL" ]; then
    echo "[install] ERROR: MT5 installation timed out after ${TIMEOUT}s"
    kill $INSTALL_PID 2>/dev/null || true
    wineserver -k 2>/dev/null || true
    exit 1
fi
echo "[install] MT5 files detected. Waiting for installer to finish..."
sleep 10
kill $INSTALL_PID 2>/dev/null || true
wineserver -k 2>/dev/null || true
sleep 3
rm -f "$WINEPREFIX/drive_c/mt5setup.exe"
echo "[install] MT5 installation complete"

# Create directory structure
mkdir -p "$EXPERTS_DIR"

echo "[install] Done. Wine prefix and MT5 are ready."

# Clean up X11 lock files so the committed image doesn't conflict with KasmVNC at runtime
rm -f /tmp/.X1-lock /tmp/.X11-unix/X1
