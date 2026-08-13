#!/bin/zsh
# Invoked by the Next.js /api/tee-demo route. Sets the toolchain PATH (foundry cast + the venv
# python with eth_account/requests) and runs the self-contained confidential-settlement demo.
# All config (DEMO_PRIVATE_KEY, ENCLAVE_URL, *_ADDR) is inherited from the caller's env.
export PATH="$HOME/.foundry/bin:/opt/homebrew/bin:/usr/bin:/bin:$PATH"
VENV=/Users/eden/data/iexec/Webwright/.venv
exec "$VENV/bin/python3" /private/tmp/claude-501/-Users-eden-data-real-agama/eea3ee8c-1c16-4169-becd-ec41a79d74a0/scratchpad/anchor-poc/enclave/tee_demo.py
