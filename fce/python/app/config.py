"""★ Configuration: version, operation identifiers and market parameters.

The op-type and op-command strings MUST match the bytes32 constants in
contracts/InstructionSender.sol exactly, or actions fall through to
"unsupported op type".
"""

from __future__ import annotations

import os

VERSION = "0.1.0"

# --- Operations --------------------------------------------------------------

OP_TYPE_RFQ = "RFQ"

# Direct action: a market maker submits a sealed, signed quote. Never on chain.
OP_COMMAND_QUOTE = "QUOTE"

# On-chain instruction from AgamaRfqInstructionSender.requestSettlement: run best
# execution over the sealed quotes and return the winning settlement.
OP_COMMAND_SETTLE = "SETTLE"

# --- Chain -------------------------------------------------------------------

# Overridable at workload launch (CHAIN_URL is in the image's allow_env_override list).
CHAIN_URL = os.environ.get("CHAIN_URL", "https://coston2-api.flare.network/ext/C/rpc")

# Flare's ContractRegistry, the same address on every Flare network.
CONTRACT_REGISTRY = "0xaD67FE66660Fb8dFE9d6b1b4240d8650e30F6019"

# FTSOv2 feed id for XRP/USD.
XRP_USD_FEED = "015852502f55534400000000000000000000000000"

# --- Market guards -----------------------------------------------------------

MAX_QUOTES_PER_RFQ = 32          # bound the work a settlement can be made to do
MIN_QUOTE_DEADLINE_SLACK = 60    # a quote must outlive settlement by this many seconds

MIN_XRP_USD_1E18 = 5 * 10**16    # $0.05: XRP/USD sanity floor
MAX_XRP_USD_1E18 = 50 * 10**18   # $50:   XRP/USD sanity ceiling
MAX_FEED_AGE = 600               # 10 min: reject a stale oracle

# A per-settlement USD risk band. MAX is the binding, oracle-derived ceiling: with
# XRP ~$0.5 a $10 cap is ~20 FXRP, tighter than a typical notional, so the FTSO
# price actually changes accept/reject rather than decorating the log.
MIN_PREMIUM_USD_1E6 = 500_000    # $0.50 floor: reject economic dust
MAX_PREMIUM_USD_1E6 = 10_000_000 # $10 cap
