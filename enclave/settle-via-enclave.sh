#!/bin/bash
# End-to-end confidential settlement through the LIVE enclave running in GCP Confidential Space (TDX).
#
# The enclave generated its own signing key inside the TEE; that key was registered on chain by
# verifying its real Google attestation token (ConfidentialSpaceRegistry). This script opens an RFQ,
# sends market-maker quotes to the enclave's /settle endpoint, and submits the settlement the enclave
# signed. Nobody (including us) holds the enclave private key: the on-chain ecrecover is the proof.
#
#   PRIVATE_KEY=0x.. ENCLAVE_URL=http://<vm-ip>:8080 RFQ=0x.. ./enclave/settle-via-enclave.sh
set -e
: "${PRIVATE_KEY:?set PRIVATE_KEY (seller/relayer)}"
ENCLAVE_URL="${ENCLAVE_URL:-http://104.155.152.64:8080}"
RFQ="${RFQ:-0x3A2BC1e41357c5ec7D6E14Cbe0caFcE17279ad4F}"       # RFQ v5, gated by the live enclave key
YT="${YT:-0x04A05b47fd57E5230a428111B9c3B45c16493752}"
FXRP="${FXRP:-0xA6fC08A750dC00e6f613e2aabaB5a54949D8B356}"
RPC="${RPC:-https://coston2-api.flare.network/ext/C/rpc}"
SELLER=$(cast wallet address --private-key "$PRIVATE_KEY")
YT_AMT="${YT_AMT:-100000000}"

# sanity: the RFQ must trust the enclave that is actually serving right now
echo "enclave /pubkey : $(curl -s $ENCLAVE_URL/pubkey)"
echo "RFQ enclaveSigner: $(cast call $RFQ 'enclaveSigner()(address)' --rpc-url $RPC)"

# fund a market maker so it can pay the YT premium
MM_PK=$(cast wallet new | awk '/Private key:/{print $3}'); MM=$(cast wallet address --private-key $MM_PK)
cast send $MM --value 2ether --private-key $PRIVATE_KEY --rpc-url $RPC >/dev/null
cast send $FXRP "mint(address,uint256)" $MM 100000000 --private-key $PRIVATE_KEY --rpc-url $RPC >/dev/null
cast send $FXRP "approve(address,uint256)" $RFQ $(cast max-uint) --private-key $MM_PK --rpc-url $RPC >/dev/null

# seller opens the RFQ (locks YT_AMT of YT in escrow)
cast send $YT "approve(address,uint256)" $RFQ $(cast max-uint) --private-key $PRIVATE_KEY --rpc-url $RPC >/dev/null
cast send $RFQ "openRfq(uint256)" $YT_AMT --private-key $PRIVATE_KEY --rpc-url $RPC >/dev/null
ID=$(( $(cast call $RFQ "nextId()(uint256)" --rpc-url $RPC | grep -oE '^[0-9]+') - 1 )); DL=$(( $(date +%s)+3600 ))
echo "opened RFQ #$ID (seller $SELLER, $YT_AMT YT)"

# sealed quotes -> the enclave picks the best, breaks ties with Flare RNG, signs the winner privately
REQ=$(printf '{"rfq":"%s","chainId":114,"rfqId":%s,"seller":"%s","ytAmount":%s,"deadline":%s,"quotes":[{"mm":"%s","price":4000000},{"mm":"0x00000000000000000000000000000000000000B2","price":3000000}]}' "$RFQ" "$ID" "$SELLER" "$YT_AMT" "$DL" "$MM")
SIG=$(curl -s -X POST "$ENCLAVE_URL/settle" -H "Content-Type: application/json" -d "$REQ")
echo "enclave signed: $SIG"
V=$(echo $SIG | python3 -c "import sys,json;print(json.load(sys.stdin)['v'])")
R=$(echo $SIG | python3 -c "import sys,json;print(json.load(sys.stdin)['r'])")
S=$(echo $SIG | python3 -c "import sys,json;print(json.load(sys.stdin)['s'])")
PRICE=$(echo $SIG | python3 -c "import sys,json;print(json.load(sys.stdin)['price'])")

# submit the enclave-signed settlement; the contract verifies it against the registered enclave key
cast send $RFQ "settle((uint256,address,address,uint256,uint256,uint256),uint8,bytes32,bytes32)" \
  "($ID,$SELLER,$MM,$YT_AMT,$PRICE,$DL)" $V $R $S --private-key $PRIVATE_KEY --rpc-url $RPC >/dev/null
echo "SETTLED on chain: seller received $PRICE FXRP premium, MM received $YT_AMT YT"
