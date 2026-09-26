#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ ! -f .env.local ]]; then
  echo "请先复制 .env.local.example 为 .env.local 并填写本机路径。" >&2
  exit 1
fi
set -a
# shellcheck disable=SC1091
source .env.local
set +a
if [[ -z "${TLS_CERT_FILE:-}" || -z "${TLS_KEY_FILE:-}" || -z "${LOCAL_STORAGE_DIR:-}" ]]; then
  echo "本地联调需要 TLS_CERT_FILE、TLS_KEY_FILE 和 LOCAL_STORAGE_DIR。" >&2
  exit 1
fi
if [[ ! -f "$TLS_CERT_FILE" || ! -f "$TLS_KEY_FILE" ]]; then
  echo "TLS 证书文件不存在。" >&2
  exit 1
fi
exec go run ./cmd/luma
