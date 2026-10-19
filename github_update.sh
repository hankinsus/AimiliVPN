#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="${INSTALL_DIR:-/opt/aimilivpn}"
DATA_DIR="${VPNGATE_DATA_DIR:-$ROOT_DIR/vpngate_data}"
LOG_FILE="$DATA_DIR/github_update.log"
PROGRESS_FILE="$DATA_DIR/github_update_progress.json"
mkdir -p "$DATA_DIR"
exec >>"$LOG_FILE" 2>&1
STEP="fetch"
FROM_COMMIT="$(git -C "$ROOT_DIR" rev-parse HEAD 2>/dev/null || true)"
TO_COMMIT=""
STARTED_AT="$(date +%s)"

progress() {
  local step="$1" error="${2:-}" tmp
  error="$(printf '%s' "$error" | tr -d '\r' | tr '\n"\\' '  /' | cut -c1-300)"
  tmp="$PROGRESS_FILE.tmp.$$"
  printf '{"step":"%s","from_commit":"%s","to_commit":"%s","started_at":%s,"at":%s,"error":"%s"}\n' \
    "$step" "$FROM_COMMIT" "$TO_COMMIT" "$STARTED_AT" "$(date +%s)" "$error" >"$tmp"
  mv -f "$tmp" "$PROGRESS_FILE"
}

on_error() {
  local code=$?
  local last
  last="$(tail -n 3 "$LOG_FILE" 2>/dev/null | tr '\n' ' ')"
  progress "failed" "${STEP} 失败（退出码 ${code}）：${last}"
  echo "[GitHub Update] failed at ${STEP} $(date -Is)"
  exit "$code"
}
trap on_error ERR

echo "[GitHub Update] started $(date -Is)"
cd "$ROOT_DIR"
progress "fetch"
git fetch --prune origin main
TO_COMMIT="$(git rev-parse origin/main)"
progress "fetch"
git checkout main
git reset --hard origin/main
STEP="install"
progress "install"
find . -type d -name __pycache__ -prune -exec rm -rf {} +
bash "$ROOT_DIR/scripts/select_core.sh" "$ROOT_DIR"
modules="vpngate_manager.py proxy_server.py"
# shellcheck disable=SC2086
python3 -m py_compile $modules
echo "[GitHub Update] build check passed $(date -Is)"
STEP="restart"
progress "restart"
systemctl restart aimilivpn
