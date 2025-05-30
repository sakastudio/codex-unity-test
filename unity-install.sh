#!/usr/bin/env bash
set -euo pipefail

# ────────────────────────────────────────────────────────────────
# 0) ユーザー設定：必須／任意環境変数
# ────────────────────────────────────────────────────────────────
: "${UNITY_EMAIL:?Error: UNITY_EMAIL is not set}"
: "${UNITY_PASSWORD:?Error: UNITY_PASSWORD is not set}"
: "${UNITY_VERSION:?Error: UNITY_VERSION is not set}"

UNITY_MODULES=${UNITY_MODULES:-""}          # 例: "android webgl"
UNITY_SERIAL=${UNITY_SERIAL:-""}            # Pro/Plus シリアル (Personal は空で OK)
UNITY_INSTALL_PATH=${UNITY_INSTALL_PATH:-"/opt/unity"}

# ★ MITM プロキシ等でルート証明書を追加したい場合はパスを渡す
MITM_CA_PATH=${MITM_CA_PATH:-""}            # 例: "./corp-root-ca.pem"

# ────────────────────────────────────────────────────────────────
# 1) 依存パッケージ Unity Hub のインストール
# ────────────────────────────────────────────────────────────────
echo ">> Installing runtime dependencies & Unity Hub ..."

sudo apt-get update

# ★ GTK と ALSA は Ubuntu 24.04 以降で t64 名に変更されたので動的判定
choose_pkg() {
  if apt-cache show "${1}t64" 2>/dev/null | grep -q '^Version:'; then
    echo "${1}t64"
  else
    echo "${1}"
  fi
}

GTK_PKG=$(choose_pkg libgtk-3-0)
ALSA_PKG=$(choose_pkg libasound2)



sudo apt-get install -y wget gpg ca-certificates libnss3 xvfb dbus-user-session \
                        "$GTK_PKG" "$ALSA_PKG"

# Unity Hub が未インストールならリポジトリ追加 → インストール
if ! command -v unityhub &>/dev/null; then
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

  sudo apt-get update
  sudo apt-get install -y unityhub
fi

# ────────────────────────────────────────────────────────────────
# 2) 追加 CA 証明書 (MITM / 社内プロキシ向け) ★
# ────────────────────────────────────────────────────────────────
if [[ -n "$MITM_CA_PATH" && -f "$MITM_CA_PATH" ]]; then
  echo ">> Installing custom root CA: $MITM_CA_PATH"
  sudo cp "$MITM_CA_PATH" "/usr/local/share/ca-certificates/$(basename "$MITM_CA_PATH").crt"
  sudo update-ca-certificates
  export NODE_EXTRA_CA_CERTS="/usr/local/share/ca-certificates/$(basename "$MITM_CA_PATH").crt"
fi

# ────────────────────────────────────────────────────────────────
# 3) Unity Hub の EULA 同意を書き込み
# ────────────────────────────────────────────────────────────────
mkdir -p "$HOME/.config/Unity Hub"
echo '{"accepted":[{"version":"3"}]}' >"$HOME/.config/Unity Hub/eulaAccepted"

# ────────────────────────────────────────────────────────────────
# 4) Unity Editor のインストール (xvfb D-Bus ラップ) ★
# ────────────────────────────────────────────────────────────────
echo ">> Installing Unity Editor $UNITY_VERSION ..."

export ELECTRON_DISABLE_GPU=true   # GPU が無い VM でもソフトレンダに

run_hub() {
  dbus-run-session -- \
    xvfb-run --auto-servernum --server-args='-screen 0 1280x720x24' \
    unityhub "$@"
}

args=(--headless install --version "$UNITY_VERSION")
if [[ -n "$UNITY_MODULES" ]]; then
  for m in $UNITY_MODULES; do args=( -m "$m" ); done
fi

run_hub "${args[@]}"

# ────────────────────────────────────────────────────────────────
# 5) (オプション) ライセンス自動アクティベーション
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
