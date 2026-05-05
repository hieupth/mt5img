#!/bin/bash
set -euo pipefail

export DISPLAY=${DISPLAY:-:1}
export WINEPREFIX=${WINEPREFIX:-/config/.wine}

MT5_DIR="${WINEPREFIX}/drive_c/Program Files/MetaTrader 5"
TERMINAL="$MT5_DIR/terminal64.exe"
EXPERTS_DIR="$MT5_DIR/MQL5/Experts"
BOTS_SRC="/bots"
CONFIG_FILE="$WINEPREFIX/drive_c/startup.ini"
MT5_PID=""

cleanup() {
    echo "[start] Shutting down..."
    kill "$MT5_PID" 2>/dev/null || true
    wineserver -k 2>/dev/null || true
    exit 0
}
trap cleanup SIGTERM SIGINT

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
    echo "[start] WARNING: wineserver wait timed out after ${timeout}s"
    kill $WAIT_PID 2>/dev/null || true
    wineserver -k 2>/dev/null || true
    sleep 2
}

# --- Read credentials from Docker secret ---
echo "[start] Reading account credentials"
LOGIN="" PASSWORD="" SERVER=""
if [ -f /run/secrets/accounts ]; then
    FIRST_LINE=$(head -1 /run/secrets/accounts)
    # Single-line format: login:password:server (must start with digits)
    if echo "$FIRST_LINE" | grep -qE '^[0-9]+:.+:.+'; then
        IFS=':' read -r LOGIN PASSWORD SERVER <<< "$FIRST_LINE"
    else
        # Multi-line format: line 2=login, line 3=password, line 4=server
        LOGIN=$(sed -n '2p' /run/secrets/accounts | tr -d '[:space:]')
        PASSWORD=$(sed -n '3p' /run/secrets/accounts | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        SERVER=$(sed -n '4p' /run/secrets/accounts | sed 's/^Server[[:space:]]*//' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        if [ -z "$SERVER" ]; then
            SERVER=$(sed -n '5p' /run/secrets/accounts | sed 's/^Server[[:space:]]*//' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        fi
    fi

    if [ -n "$LOGIN" ] && [ -n "$PASSWORD" ] && [ -n "$SERVER" ]; then
        echo "[start] Account: login=$LOGIN server=$SERVER"
    else
        echo "[start] WARNING: Could not parse credentials (login='$LOGIN' server='$SERVER')"
        LOGIN="" PASSWORD="" SERVER=""
    fi
else
    echo "[start] WARNING: /run/secrets/accounts not found"
fi

# --- Copy bot files from /bots to Experts directory ---
if [ -d "$BOTS_SRC" ] && [ "$(ls -A "$BOTS_SRC" 2>/dev/null)" ]; then
    echo "[start] Copying bot files from $BOTS_SRC"
    for f in "$BOTS_SRC"/*; do
        base=$(basename "$f")
        # Rename .c files to .mq5 so MetaEditor can compile them
        if [[ "$base" == *.c ]]; then
            new_name="${base%.c}.mq5"
            echo "[start]   $base -> $new_name (.c renamed to .mq5)"
            cp -v "$f" "$EXPERTS_DIR/$new_name"
        else
            cp -v "$f" "$EXPERTS_DIR"/
        fi
    done
else
    echo "[start] WARNING: No bot files found in $BOTS_SRC"
fi

# --- Find EA to run (prefer .ex5, fallback to .mq5) ---
EA_NAME=""
shopt -s nullglob
EX5_FILES=("$EXPERTS_DIR"/*.ex5)
MQ5_FILES=("$EXPERTS_DIR"/*.mq5)
shopt -u nullglob

if [ ${#EX5_FILES[@]} -gt 0 ]; then
    EA_NAME=$(basename "${EX5_FILES[0]}" .ex5)
    echo "[start] Found EA: $EA_NAME (.ex5)"
elif [ ${#MQ5_FILES[@]} -gt 0 ]; then
    EA_NAME=$(basename "${MQ5_FILES[0]}" .mq5)
    echo "[start] Found EA: $EA_NAME (.mq5, needs compilation)"
else
    echo "[start] WARNING: No EA files found. Starting MT5 without EA."
fi

# --- Pre-compile phase: if .mq5 exists but no .ex5, run MT5 briefly to compile ---
# MetaEditor /compile is unreliable under Wine, so we use MT5's internal compiler.
# Launch MT5 without an EA config, wait for compilation to finish, then stop it.
if [ -n "$EA_NAME" ] && [ ${#EX5_FILES[@]} -eq 0 ] && [ ${#MQ5_FILES[@]} -gt 0 ]; then
    echo "[start] Pre-compile: launching MT5 to compile .mq5 files..."
    wine "$TERMINAL" /portable &
    MT5_PID=$!

    # Wait for .ex5 files to appear (MT5's internal compiler produces them)
    COMPILE_WAIT=0
    COMPILE_TIMEOUT=120
    expected_ex5="${MQ5_FILES[0]%.*}.ex5"
    while [ ! -f "$expected_ex5" ] && [ $COMPILE_WAIT -lt $COMPILE_TIMEOUT ]; do
        sleep 3
        COMPILE_WAIT=$((COMPILE_WAIT + 3))
        if [ $((COMPILE_WAIT % 15)) -eq 0 ]; then
            echo "[start] Pre-compile: waiting for $(basename "$expected_ex5")... (${COMPILE_WAIT}s)"
        fi
    done

    if [ -f "$expected_ex5" ]; then
        echo "[start] Pre-compile: $(basename "$expected_ex5") produced successfully"
    else
        echo "[start] Pre-compile: WARNING: compilation did not produce .ex5 within ${COMPILE_TIMEOUT}s"
    fi

    # Stop the temporary MT5 instance
    echo "[start] Pre-compile: stopping temporary MT5 instance..."
    kill $MT5_PID 2>/dev/null || true
    wineserver -k 2>/dev/null || true
    sleep 3
    MT5_PID=""

    # Re-check for .ex5 files
    shopt -s nullglob
    EX5_FILES=("$EXPERTS_DIR"/*.ex5)
    shopt -u nullglob
    if [ ${#EX5_FILES[@]} -gt 0 ]; then
        EA_NAME=$(basename "${EX5_FILES[0]}" .ex5)
        echo "[start] Found EA after compilation: $EA_NAME (.ex5)"
    fi
fi

# --- Generate startup.ini if credentials are available ---
if [ -n "$LOGIN" ]; then
    cat > "$CONFIG_FILE" << EOF
[Common]
Login=$LOGIN
Password=$PASSWORD
Server=$SERVER
KeepPrivate=1
NewsEnable=0

[Experts]
AllowLiveTrading=1
AllowDllImport=0
Enabled=1
Account=0

[StartUp]
EOF
    if [ -n "$EA_NAME" ]; then
        echo "Expert=$EA_NAME" >> "$CONFIG_FILE"
    fi
    echo "Symbol=EURUSD" >> "$CONFIG_FILE"
    echo "Period=H1" >> "$CONFIG_FILE"
    echo "[start] Config written to startup.ini"
fi

# --- Launch MT5 ---
echo "[start] Launching MetaTrader 5..."
if [ -n "$LOGIN" ] && [ -f "$CONFIG_FILE" ]; then
    wine "$TERMINAL" /portable /config:"C:\\startup.ini" &
else
    wine "$TERMINAL" /portable &
fi
MT5_PID=$!
echo "[start] MetaTrader 5 launched (PID=$MT5_PID)"

wait $MT5_PID
