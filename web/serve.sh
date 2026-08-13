#!/bin/zsh
# Persistent production server for the Agama fixed-rate dApp (launchd keeps it alive
# across the sandbox killing long processes).
export PATH="/opt/homebrew/bin:/Users/eden/.nvm/versions/node/v22.22.2/bin:/usr/bin:/bin:$PATH"
cd /private/tmp/claude-501/-Users-eden-data-real-agama/eea3ee8c-1c16-4169-becd-ec41a79d74a0/scratchpad/anchor-poc/web
exec pnpm start
