#!/usr/bin/env bash
# Fetches llama.cpp at a pinned revision for the arm64 JNI build.
#
# Pinned rather than tracking master: llama.cpp changes its C API often enough
# (llama_chat_apply_template gained a model argument, sampling moved to
# llama_sampler_chain) that an unpinned build breaks without warning.
set -euo pipefail
cd "$(dirname "$0")"

PIN_FILE="llama-pin.txt"
PIN="${1:-$(cat "$PIN_FILE" 2>/dev/null || echo master)}"

if [ ! -d llama.cpp/.git ]; then
    echo "cloning llama.cpp (shallow)…"
    rm -rf llama.cpp
    git clone --depth 1 https://github.com/ggml-org/llama.cpp.git
fi

cd llama.cpp
if [ "$PIN" != "master" ]; then
    git fetch --depth 1 origin "$PIN"
    git checkout --quiet "$PIN"
fi
git rev-parse HEAD | tee "../$PIN_FILE.new" >/dev/null
mv "../$PIN_FILE.new" "../$PIN_FILE"
echo "llama.cpp at $(cat "../$PIN_FILE")"
