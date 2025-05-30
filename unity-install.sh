#!/usr/bin/env bash
# Fully-automated Unity Hub & Editor installer for headless Ubuntu
#   • Handles lib* t64 packages (24.04+)
#   • Wraps Unity Hub in dbus-run-session + xvfb
#   • Installs mitmproxy, generates root CA, and registers it system-wide
#   • Supports corporate proxy via HTTPS_PROXY / HTTP_PROXY

set -euo pipefail

# ────────────────────────────────────────────────────────────────
# 0) 必須 / 任意環境変数
# ────────────────────────────────────────────────────────────────
: "${UNITY_EMAIL:?Error: UNITY_EMAIL is not set}"
: "${UNITY_PASSWORD:?Error: UNITY_PASSWORD is not set}"
: "${UNITY_VERSION:?Error: UNITY_VERSION is not set}"

UNITY_MODULES=${UNITY_MODULES:-""}          # e.g. "android webgl"
UNITY_SERIAL=${UNITY_SERIAL:-""}            # Pro/Plus serial (empty = Personal)
UNITY_INSTALL_PATH=${UNITY_INSTALL_PATH:-"/opt/unity"}

# ────────────────────────────────────────────────────────────────
# 1) 依存パッケージの導入（Ubuntu 22.04 / 24.04 両対応）
# ────────────────────────────────────────────────────────────────
sudo apt-get update -y

choose_pkg() {                    # $1 = base name (libgtk-3-0 / libasound2)
  if apt-cache show "${1}t64" 2>/dev/null | grep -q '^Version:'; then
    echo "${1}t64"               # Ubuntu 24.04+
  else
    echo "${1}"                  # Ubuntu 22.04-
  fi
}

GTK_PKG=$(choose_pkg libgtk-3-0)
ALSA_PKG=$(choose_pkg libasound2)

sudo apt-get install -y \
  wget gpg ca-certificates libnss3 xvfb dbus-user-session \
  "$GTK_PKG" "$ALSA_PKG" \
  mitmproxy                           # mitmproxy も同時に入れる

# ────────────────────────────────────────────────────────────────
# 2) mitmproxy ルート CA を生成 → システム & Electron 登録
# ────────────────────────────────────────────────────────────────
MITM_CA="$HOME/.mitmproxy/mitmproxy-ca-cert.pem"
if [[ ! -f "$MITM_CA" ]]; then
  echo ">> Generating mitmproxy root certificate..."
  # 初回のみ ~/.mitmproxy に CA を生成
  mitmdump --help >/dev/null 2>&1
fi

if [[ -f "$MITM_CA" ]]; then
  echo ">> Installing mitmproxy root CA to system trust store"
  sudo cp "$MITM_CA" /usr/local/share/ca-certificates/mitmproxy-ca.crt
  sudo update-ca-certificates
  export NODE_EXTRA_CA_CERTS="/usr/local/share/ca-certificates/mitmproxy-ca.crt"
fi

# オプション: 企業プロキシがあるなら HTTPS_PROXY を事前に set しておく
if [[ -n "${HTTPS_PROXY:-}" ]]; then
  export HTTP_PROXY="$HTTPS_PROXY"
  export NO_PROXY="localhost,127.0.0.1"
fi

# ────────────────────────────────────────────────────────────────
# 3) Unity Hub のインストール（未インストール時のみ）
# ────────────────────────────────────────────────────────────────
if ! command -v unityhub &>/dev/null; then
  echo ">> Installing Unity Hub..."
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
fi

# ────────────────────────────────────────────────────────────────
# 4) system D-Bus が無いコンテナ用の暫定バス起動
# ────────────────────────────────────────────────────────────────
if [[ ! -S /run/dbus/system_bus_socket ]]; then
  echo ">> Starting ad-hoc system D-Bus"
  sudo dbus-daemon --system --fork --nopidfile
fi

# ────────────────────────────────────────────────────────────────
# 5) Hub EULA 同意ファイルを作成
# ────────────────────────────────────────────────────────────────
mkdir -p "$HOME/.config/Unity Hub"
echo '{"accepted":[{"version":"3"}]}' >"$HOME/.config/Unity Hub/eulaAccepted"

# ────────────────────────────────────────────────────────────────
# 6) Unity Editor のインストール
# ────────────────────────────────────────────────────────────────
echo ">> Installing Unity Editor $UNITY_VERSION ..."

export ELECTRON_DISABLE_GPU=true   # GPU 無しでもソフトレンダに

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
# 7) （任意）ライセンス自動アクティベーション
# ────────────────────────────────────────────────────────────────
if [[ -n "$UNITY_SERIAL" ]]; then
  EDITOR="$HOME/Unity/Hub/Editor/$UNITY_VERSION/Editor/Unity"
  [[ -x $EDITOR ]] || EDITOR="$UNITY_INSTALL_PATH/Hub/Editor/$UNITY_VERSION/Editor/Unity"
  if [[ -x $EDITOR ]]; then
    echo ">> Activating license ..."
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
