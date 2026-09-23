#!/usr/bin/env bash
set -Eeuo pipefail

if [ "${EUID}" -ne 0 ]; then
  echo "Error: run this script as root." >&2
  exit 1
fi

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

bash "$SCRIPT_DIR/module/0.init.sh"
bash "$SCRIPT_DIR/module/1.create_user.sh"
bash "$SCRIPT_DIR/module/2.init_ssh.sh"
bash "$SCRIPT_DIR/module/3.init_ufw.sh"
# bash "$SCRIPT_DIR/module/4.init_deploy.sh"
