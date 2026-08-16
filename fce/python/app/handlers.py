"""★ MAIN CUSTOMIZATION POINT: Agama's confidential YT market.

Two operations, one per channel into the enclave:

  RFQ / QUOTE   direct action — a market maker submits a sealed, signed quote.
                It is authenticated and kept in enclave memory. Nothing about it
                reaches the chain, the proxy's logs, or any other market maker.

  RFQ / SETTLE  on-chain instruction from AgamaRfqInstructionSender —
                best execution over the quotes held for that RFQ. Only the
                winning settlement is returned, and the TEE node signs it so the
                contract can verify it before moving any funds.

Handler contract:
    (original_message_hex) -> (data_hex_or_None, status, error_or_None)
    status 0 = error, 1 = success. See docs/extension-contract.md §4.6.

The framework serializes handler calls, so plain module-level state is safe.
"""

from __future__ import annotations

import json
import logging
from typing import Any, Optional

from base.encoding import bytes_to_hex, hex_to_bytes
from base.node import NodeClient
from base.types import CHANNEL_ONCHAIN, Framework

from . import chain, quotes
from .abi import decode_settle_message, encode_settlement
from .config import (
    MIN_QUOTE_DEADLINE_SLACK,
    OP_COMMAND_QUOTE,
    OP_COMMAND_SETTLE,
    OP_TYPE_RFQ,
    VERSION,
)
from .quotes import QuoteError

logger = logging.getLogger(__name__)

# --- Extension state ---------------------------------------------------------
# Counters only. The quote book itself lives in app/quotes.py and never leaves it.
_quotes_accepted = 0
_quotes_rejected = 0
_settlements_signed = 0

_node: Optional[NodeClient] = None


def set_sign_port(port: str | int) -> None:
    """Point the ECIES decryption calls at the tee-node signing API."""
    global _node
    _node = NodeClient(port)


def reset_state() -> None:
    """Reset counters and the book. Used by tests; not part of the wire contract."""
    global _quotes_accepted, _quotes_rejected, _settlements_signed
    _quotes_accepted = _quotes_rejected = _settlements_signed = 0
    quotes.reset()


def register(framework: Framework) -> None:
    """Wire handlers to (opType, opCommand) pairs.

    The channel restriction on SETTLE is load-bearing, not decoration. SETTLE
    runs best execution over the sealed book and returns the winner and price,
    signed by the TEE; it must arrive ONLY as an on-chain instruction from
    AgamaRfqInstructionSender.requestSettlement, never over the proxy's public
    /direct endpoint — otherwise any anonymous caller reads the book and collects
    a TEE-signed settlement (verified exploitable against the live deployment).

    QUOTE stays reachable on both channels. A market maker submits it over
    /direct so the quote never touches the chain; an on-chain QUOTE would merely
    make the submitter's own quote public, harms nobody else, and is never
    emitted in production — so there is no reason to reject it and break the
    recorded wire-contract fixtures that exercise QUOTE as an instruction.
    """
    framework.handle(OP_TYPE_RFQ, OP_COMMAND_QUOTE, handle_quote)
    framework.handle(OP_TYPE_RFQ, OP_COMMAND_SETTLE, handle_settle, channels=(CHANNEL_ONCHAIN,))


def report_state() -> Any:
    """Snapshot returned by GET /state.

    Deliberately counts only: prices, market makers and the book itself are the
    confidential part of this extension, so nothing that could reconstruct a
    quote is exposed here.
    """
    rfqs_tracked, quotes_held = quotes.book_size()
    return {
        "version": VERSION,
        "rfqsTracked": rfqs_tracked,
        "quotesHeld": quotes_held,
        "quotesAccepted": _quotes_accepted,
        "quotesRejected": _quotes_rejected,
        "settlementsSigned": _settlements_signed,
    }


def _decode_payload(msg: str) -> dict:
    """Decode a quote payload, transparently unwrapping an ECIES envelope.

    A market maker that does not want the proxy operator to see its price sends
    {"enc": "<hex ciphertext under the TEE public key>"}; the enclave asks the
    tee-node to decrypt it and finds the same JSON inside.
    """
    raw = hex_to_bytes(msg)
    try:
        payload = json.loads(raw)
    except (json.JSONDecodeError, ValueError) as e:
        raise QuoteError(f"payload is not JSON: {e}") from e
    if not isinstance(payload, dict):
        raise QuoteError("payload must be a JSON object")

    envelope = payload.get("enc")
    if envelope is None:
        return payload

    if _node is None:
        raise QuoteError("encrypted quotes need the tee-node signing port")
    try:
        ciphertext = bytes.fromhex(str(envelope).removeprefix("0x"))
    except ValueError as e:
        raise QuoteError(f"enc is not hex: {e}") from e
    try:
        inner = json.loads(_node.decrypt(ciphertext))
    except RuntimeError as e:
        raise QuoteError(f"decryption failed: {e}") from e
    except (json.JSONDecodeError, ValueError) as e:
        raise QuoteError(f"decrypted payload is not JSON: {e}") from e
    if not isinstance(inner, dict):
        raise QuoteError("decrypted payload must be a JSON object")
    return inner


def handle_quote(msg: str) -> tuple[Optional[str], int, Optional[str]]:
    """RFQ/QUOTE — a sealed, MM-signed quote submitted as a direct action."""
    global _quotes_accepted, _quotes_rejected

    # 1. Decode (and decrypt, if the market maker sealed it)
    try:
        payload = _decode_payload(msg)
    except QuoteError as e:
        _quotes_rejected += 1
        return None, 0, str(e)

    # 2. Validate against the chain: RFQ terms, reserve, deadline, MM signature
    try:
        quote, _yt_amount = quotes.parse_quote(payload, chain.chain_id())
        held = quotes.store(quote)
    except QuoteError as e:
        _quotes_rejected += 1
        return None, 0, str(e)
    except chain.ChainError as e:
        _quotes_rejected += 1
        return None, 0, f"chain read failed: {e}"

    # 3. Acknowledge without leaking the book: the count, never the prices
    _quotes_accepted += 1
    logger.info("quote accepted for rfq %s#%d (%d live)", quote.rfq, quote.rfq_id, held)
    data = json.dumps({"accepted": True, "rfqId": quote.rfq_id, "quotesHeld": held})
    return bytes_to_hex(data.encode()), 1, None


def handle_settle(msg: str) -> tuple[Optional[str], int, Optional[str]]:
    """RFQ/SETTLE — best execution over the sealed quotes; only the winner comes out."""
    global _settlements_signed

    # 1. Decode the on-chain instruction: ABI-encoded (rfqId, contractAddr)
    try:
        rfq_id, contract_addr = decode_settle_message(hex_to_bytes(msg))
    except ValueError as e:
        return None, 0, f"decoding request: {e}"

    # 2. Read the authoritative terms from the contract, never from the caller
    try:
        seller, yt_amount, min_price, _settle_by, is_open = chain.read_rfq(contract_addr, rfq_id)
        if not is_open:
            # Settled or cancelled on chain: the quotes can never be used again.
            quotes.drop(contract_addr, rfq_id)
            return None, 0, "rfq not open"
        fxrp = chain.read_fxrp(contract_addr)
    except chain.ChainError as e:
        return None, 0, f"chain read failed: {e}"

    # 3. Re-authenticate every held quote, then run best execution
    candidates = quotes.quotes_for(contract_addr, rfq_id)
    if not candidates:
        return None, 0, "no quotes held for this rfq"
    try:
        now = chain.latest_block_timestamp()
        # Require the same slack settle-time as at ingest: a quote judged live here
        # is about to be signed and relayed, and the contract enforces
        # `block.timestamp <= deadline`. Accepting a quote that merely outlives
        # `now` lets the enclave sign a settlement that expires before the relayer
        # can land it, which then reverts on chain — a signed result that can never
        # be used. Binding to now + slack keeps a signed settlement relayable.
        live = [q for q in candidates if q.deadline > now + MIN_QUOTE_DEADLINE_SLACK]
        if not live:
            return None, 0, "every held quote expires too soon to settle"
        winner, premium_usd = quotes.choose_winner(live, yt_amount, min_price, fxrp, contract_addr)
    except QuoteError as e:
        return None, 0, str(e)
    except chain.ChainError as e:
        return None, 0, f"chain read failed: {e}"

    # 4. Only the winning settlement leaves the enclave. The node signs this result;
    #    the contract verifies that signature and re-checks every field on chain.
    data = encode_settlement(
        contract_addr=contract_addr,
        rfq_id=rfq_id,
        seller=seller,
        winner=winner.mm,
        yt_amount=yt_amount,
        price=winner.price,
        deadline=winner.deadline,
    )
    # The book is NOT dropped here. Signing a settlement does not settle anything:
    # the relayer may never submit it, or the transaction may revert, and the RFQ
    # would then be stuck with an enclave that has forgotten every quote. It is
    # dropped when the RFQ is next seen closed on chain.
    _settlements_signed += 1
    logger.info(
        "settlement signed for rfq %s#%d: %d candidates, premium %d (USD 6dp %d)",
        contract_addr,
        rfq_id,
        len(live),
        winner.price,
        premium_usd,
    )
    return bytes_to_hex(data), 1, None
