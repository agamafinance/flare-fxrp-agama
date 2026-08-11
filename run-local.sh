#!/bin/zsh
# Local Anchor demo: fresh anvil + deploy + static front server.
# Deterministic addresses (anvil acct #0 from nonce 0) match frontend/app.html CONFIG.local.
# Then open http://127.0.0.1:8547/app.html and pick the "Local (anvil)" network.
export PATH="$HOME/.foundry/bin:$PATH"
DIR="$(cd "$(dirname "$0")" && pwd)"
ANVIL_KEY=0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80 # well-known public anvil test key

lsof -ti tcp:8546 | xargs kill -9 2>/dev/null
lsof -ti tcp:8547 | xargs kill -9 2>/dev/null
sleep 1

cd "$DIR" || exit 1
anvil --silent --port 8546 --host 127.0.0.1 &
ANVIL_PID=$!
sleep 3

PRIVATE_KEY=$ANVIL_KEY forge script script/Deploy.s.sol:Deploy \
  --rpc-url http://127.0.0.1:8546 --broadcast > /tmp/anchor-deploy.log 2>&1

cd "$DIR/frontend" || exit 1
python3 -m http.server 8547 --bind 127.0.0.1 &
HTTP_PID=$!

wait $ANVIL_PID
kill $HTTP_PID 2>/dev/null
