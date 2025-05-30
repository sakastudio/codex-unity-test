#!/usr/bin/env bash
# Fully-automated Unity Hub & Editor installer for headless Ubuntu
#   • Handles lib* t64 packages (24.04+)
#   • Wraps Unity Hub in dbus-run-session + xvfb
#   • Installs mitmproxy, generates root CA, and registers it system-wide
#   • Extracts corporate-proxy root CA automatically (HTTPS_PROXY / HTTP_PROXY)
#   • Falls back to UnityHub.AppImage if the apt repository is blocked

set -euo pipefail

# ────────────────────────────────────────────────────────────────
# 0) 必須 / 任意環境変数
# ────────────────────────────────────────────────────────────────
: "${UNITY_EMAIL:?Error: UNITY_EMAIL is not set}"
: "${UNITY_PASSWORD:?Error: UNITY_PASSWORD is not set}"
: "${UNITY_VERSION:?Error: UNITY_VERSION is not set}"

UNITY_MODULES=${UNITY_MODULES:-""}           # 例: "android webgl"
UNITY_SERIAL=${UNITY_SERIAL:-""}             # Pro/Plus serial (Personal は空で OK)
UNITY_INSTALL_PATH=${UNITY_INSTALL_PATH:-"/opt/unity"}

# ────────────────────────────────────────────────────────────────
# 1) 依存パッケージ導入（Ubuntu 22.04 / 24.04 両対応）
# ────────────────────────────────────────────────────────────────
sudo apt-get update -y

choose_pkg() {                              # $1 = libgtk-3-0 / libasound2
  if apt-cache show "${1}t64" 2>/dev/null | grep -q '^Version:'; then
    echo "${1}t64"                          # Ubuntu 24.04 以降
  else
    echo "${1}"                             # Ubuntu 22.04 以前
  fi
}

GTK_PKG=$(choose_pkg libgtk-3-0)
ALSA_PKG=$(choose_pkg libasound2)

sudo apt-get install -y \
  wget gpg ca-certificates libnss3 xvfb dbus-user-session openssl \
  libfuse2t64 \                               # ← AppImage 実行用に追加
  "$GTK_PKG" "$ALSA_PKG" \
  mitmproxy

# ────────────────────────────────────────────────────────────────
# 2) mitmproxy ルート CA を生成 → システム & Electron 登録
# ────────────────────────────────────────────────────────────────
MITM_CA="$HOME/.mitmproxy/mitmproxy-ca-cert.pem"
if [[ ! -f "$MITM_CA" ]]; then
  echo ">> Generating mitmproxy root certificate (short-lived proxy)…"
  ( mitmdump -q --listen-host 127.0.0.1 --listen-port 8085 \
      --set block_global=false & MDPID=$! ; sleep 5 ; kill "$MDPID" >/dev/null 2>&1 ) || true
fi

if [[ -f "$MITM_CA" ]]; then
  echo ">> Installing mitmproxy root CA to system trust store"
  sudo cp "$MITM_CA" /usr/local/share/ca-certificates/mitmproxy-ca.crt
  sudo update-ca-certificates
  export NODE_EXTRA_CA_CERTS="/usr/local/share/ca-certificates/mitmproxy-ca.crt"
fi

# ────────────────────────────────────────────────────────────────
# 3) HTTPS_PROXY があれば実際の proxy ルート CA を自動抽出して登録
# ────────────────────────────────────────────────────────────────
if [[ -n "${HTTPS_PROXY:-}" ]]; then
  echo ">> Attempting to extract proxy root CA via OpenSSL"
  PROXY=${HTTPS_PROXY#http://}              # scheme を除去
  TMP_CA=$(mktemp)

  openssl s_client -showcerts -servername hub.unity3d.com \
      -connect hub.unity3d.com:443 -proxy "${PROXY}" </dev/null 2>/dev/null |
  sed -n '/-----BEGIN CERTIFICATE-----/,/-----END CERTIFICATE-----/p' |
  tac | sed -n '/-----END CERTIFICATE-----/,/-----BEGIN CERTIFICATE-----/p' | tac \
    > "$TMP_CA"

  if grep -q "BEGIN CERTIFICATE" "$TMP_CA"; then
    echo ">> Installing proxy root CA to system trust store"
    sudo cp "$TMP_CA" /usr/local/share/ca-certificates/proxy-root-ca.crt
    sudo update-ca-certificates
    export NODE_EXTRA_CA_CERTS="/usr/local/share/ca-certificates/proxy-root-ca.crt:${NODE_EXTRA_CA_CERTS:-}"
  else
    echo "!! Failed to extract proxy root CA – continuing without it"
  fi
  rm -f "$TMP_CA"
fi

# 企業プロキシ: HTTP(S)_PROXY / NO_PROXY を Unity Hub 実行前に設定
if [[ -n "${HTTPS_PROXY:-}" ]]; then
  export HTTP_PROXY="$HTTPS_PROXY"
  export NO_PROXY="localhost,127.0.0.1"
fi

# ────────────────────────────────────────────────────────────────
# 4) Unity Hub のインストール（未インストール時のみ / フォールバックあり）
# ────────────────────────────────────────────────────────────────
install_hub_appimage() {                    # ← フォールバック関数
  echo ">> Falling back to direct UnityHub.AppImage download"
  HUB_URL="https://public-cdn.cloud.unity3d.com/hub/prod/UnityHub.AppImage"
  sudo wget -qO /usr/local/bin/unityhub "$HUB_URL"
  sudo chmod +x /usr/local/bin/unityhub
  echo ">> Unity Hub AppImage installed to /usr/local/bin/unityhub"
}

if ! command -v unityhub &>/dev/null; then
  echo ">> Installing Unity Hub…"

  set +e
  {
    wget -qO - https://hub.unity3d.com/linux/keys/public \
      | gpg --dearmor \
      | sudo tee /usr/share/keyrings/Unity_Technologies_ApS.gpg >/dev/null

    sudo tee /etc/apt/sources.list.d/unityhub.sources >/dev/null <<'EOF'
Types: deb
URIs: https://hub.unity3d.com/linux/repos/deb
Suites: stable
Components: main
Signed-By: /usr/share/keyrings/Unity_Technologies_ApS.gpg
EOF

    sudo apt-get update -y
    sudo apt-get install -y unityhub
  }
  HUB_STATUS=$?
  set -e

  if [[ $HUB_STATUS -ne 0 ]]; then
    echo "!! apt install unityhub failed (${HUB_STATUS}) – switching to AppImage"
    install_hub_appimage
  fi
fi

# ────────────────────────────────────────────────────────────────
# 5) system D-Bus が無いコンテナ用の暫定バス起動
# ────────────────────────────────────────────────────────────────
if [[ ! -S /run/dbus/system_bus_socket ]]; then
  echo ">> Starting ad-hoc system D-Bus"
  sudo dbus-daemon --system --fork --nopidfile
fi

# ────────────────────────────────────────────────────────────────
# 6) Hub EULA 同意ファイル
# ────────────────────────────────────────────────────────────────
mkdir -p "$HOME/.config/Unity Hub"
echo '{"accepted":[{"version":"3"}]}' > "$HOME/.config/Unity Hub/eulaAccepted"

# ────────────────────────────────────────────────────────────────
# 7) Unity Editor のインストール
# ────────────────────────────────────────────────────────────────
echo ">> Installing Unity Editor $UNITY_VERSION …"

export ELECTRON_DISABLE_GPU=true            # GPU 無しでも OK

run_hub() {
  dbus-run-session -- \
    xvfb-run --auto-servernum --server-args='-screen 0 1280x720x24' \
    unityhub "$@"
}

args=(--headless install --version "$UNITY_VERSION")
if [[ -n "$UNITY_MODULES" ]]; then
  for m in $UNITY_MODULES; do args+=( -m "$m" ); done
fi
run_hub "${args[@]}"

# ────────────────────────────────────────────────────────────────
# 8) （任意）ライセンス自動アクティベーション
# ────────────────────────────────────────────────────────────────
if [[ -n "$UNITY_SERIAL" ]]; then
  EDITOR="$HOME/Unity/Hub/Editor/$UNITY_VERSION/Editor/Unity"
  [[ -x $EDITOR ]] || EDITOR="$UNITY_INSTALL_PATH/Hub/Editor/$UNITY_VERSION/Editor/Unity"
  if [[ -x $EDITOR ]]; then
    echo ">> Activating license …"
    dbus-run-session -- xvfb-run --auto-servernum \
      "$EDITOR" -quit -batchmode -nographics \
      -serial "$UNITY_SERIAL" \
      -username "$UNITY_EMAIL" \
      -password "$UNITY_PASSWORD" || true
  else
    echo "!! Editor binary not found – licence activation skipped."
  fi
else
  echo ">> UNITY_SERIAL not set – licence activation skipped (Personal licence assumed)."
fi

echo "✅ Unity $UNITY_VERSION installation finished."
