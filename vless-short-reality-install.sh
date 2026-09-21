#!/usr/bin/env bash
# 兼容入口。完整实现在 vless-short-chain.sh，本文件只负责转过去。
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec bash "${here}/vless-short-chain.sh" "$@"
