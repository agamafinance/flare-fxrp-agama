#!/bin/zsh
# Enclave + relayer for a demo: given an open RFQ, spin up a market maker, have the enclave
# pick best execution and sign, then relay the settlement on chain. In production the enclave
# runs in GCP Confidential Space and the MMs are real; here one MM is funded for the demo.
#
# Usage:
#   PRIVATE_KEY=0x<relayer/funder> ./script/settle-rfq.sh <rfqId> <seller> <ytAmount> [price]
# Reads the enclave key from .env.enclave. Addresses default to the live Coston2 deployment.
set -e
export PATH="$HOME/.foundry/bin:$PATH"
DIR="$(cd "$(dirname "$0")/.." && pwd)"
source "$DIR/.env.enclave"   # ENCLAVE_PK
RPC=${RPC:-https://coston2-api.flare.network/ext/C/rpc}
RFQ=${RFQ:-0x85Cc6f149A6A88F67025fcF4359645f288c86BF6}
FXRP=${FXRP:-0xA6fC08A750dC00e6f613e2aabaB5a54949D8B356}

RFQ_ID=$1; SELLER=$2; YT_AMOUNT=$3; PRICE=${4:-2000000}
DL=$(( $(date +%s) + 3600 ))
[ -z "$RFQ_ID" ] && { echo "usage: settle-rfq.sh <rfqId> <seller> <ytAmount> [price]"; exit 1; }

# fund a market maker so it can pay the premium
MM_PK=$(cast wallet new 2>/dev/null | awk '/Private key:/{print $3}')
MM=$(cast wallet address --private-key $MM_PK)
echo "market maker: $MM"
cast send $MM --value 2ether --private-key $PRIVATE_KEY --rpc-url $RPC >/dev/null
cast send $FXRP "mint(address,uint256)" $MM $((PRICE*2)) --private-key $PRIVATE_KEY --rpc-url $RPC >/dev/null
cast send $FXRP "approve(address,uint256)" $RFQ $(cast max-uint) --private-key $MM_PK --rpc-url $RPC >/dev/null

# enclave: sealed quotes in, best execution out, signed
RESULT=$(ENCLAVE_PK=$ENCLAVE_PK RFQ=$RFQ RFQ_ID=$RFQ_ID SELLER=$SELLER YT_AMOUNT=$YT_AMOUNT DEADLINE=$DL \
  QUOTE_MMS=$MM QUOTE_PRICES=$PRICE \
  forge script "$DIR/script/Enclave.s.sol:Enclave" --rpc-url $RPC 2>&1 | grep "RESULT")
V=$(echo $RESULT | sed -E 's/.* v=([0-9]+) .*/\1/')
R=$(echo $RESULT | sed -E 's/.* r=(0x[0-9a-fA-F]+) .*/\1/')
S=$(echo $RESULT | sed -E 's/.* s=(0x[0-9a-fA-F]+).*/\1/')
echo "enclave signed: winner=$MM price=$PRICE v=$V"

# relayer settles the enclave-signed winner
cast send $RFQ "settle((uint256,address,address,uint256,uint256,uint256),uint8,bytes32,bytes32)" \
  "($RFQ_ID,$SELLER,$MM,$YT_AMOUNT,$PRICE,$DL)" $V $R $S --private-key $PRIVATE_KEY --rpc-url $RPC >/dev/null
echo "settled RFQ #$RFQ_ID: $YT_AMOUNT YT -> $MM for $PRICE FXRP -> $SELLER"
