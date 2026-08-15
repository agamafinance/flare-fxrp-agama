"""★ Sealed quotes: authentication, the book, and best execution.

The book lives only here, in enclave memory. A quote is accepted only if the
market maker signed it (so nobody can quote on someone else's behalf, or replay
a quote into another RFQ or another chain), and a settlement is produced only
from quotes at or above the seller's on-chain reserve and inside the FTSO USD
band. Losing quotes never leave this process.
"""

from __future__ import annotations

import threading
from dataclasses import dataclass

from eth_abi import encode as abi_encode
from eth_keys import KeyAPI
from eth_utils import keccak

from . import chain
from .config import (
    MAX_PREMIUM_USD_1E6,
    MAX_QUOTES_PER_RFQ,
    MIN_PREMIUM_USD_1E6,
    MIN_QUOTE_DEADLINE_SLACK,
)

_keys = KeyAPI()


class QuoteError(ValueError):
    """A quote was malformed, unauthentic, or outside the market's guards."""


@dataclass(frozen=True)
class Quote:
    rfq: str        # the RFQ contract, lowercase
    rfq_id: int
    mm: str         # market maker, lowercase
    price: int      # FXRP premium offered, in token units
    deadline: int   # unix seconds after which the quote is void


# (rfq, rfqId) -> {mm: Quote}. One live quote per market maker; a new one replaces it.
_book: dict[tuple[str, int], dict[str, Quote]] = {}
_book_lock = threading.Lock()


def quote_digest(chain_id: int, rfq: str, rfq_id: int, mm: str, yt_amount: int, price: int, deadline: int) -> bytes:
    """The preimage a market maker signs. Mirrors AgamaRfqInstructionSender.quoteDigest."""
    return keccak(
        abi_encode(
            ["string", "uint256", "address", "uint256", "address", "uint256", "uint256", "uint256"],
            ["AnchorQuote", chain_id, rfq, rfq_id, mm, yt_amount, price, deadline],
        )
    )


def recover(digest: bytes, signature: bytes) -> str:
    """Recover the signer of a 65-byte (r,s,v) signature over `digest`, lowercase."""
    if len(signature) != 65:
        raise QuoteError("signature must be 65 bytes")
    v = signature[64]
    if v >= 27:
        v -= 27
    if v not in (0, 1):
        raise QuoteError("signature has an invalid v")
    sig = _keys.Signature(signature_bytes=signature[:64] + bytes([v]))
    return _keys.ecdsa_recover(digest, sig).to_address().lower()


def parse_quote(payload: dict, chain_id: int) -> tuple[Quote, int]:
    """Validate a submitted quote against the chain and the market's guards.

    Returns the quote and the RFQ's YT amount. Raises QuoteError on anything
    the enclave will not stand behind.
    """
    try:
        rfq = str(payload["rfq"]).lower()
        rfq_id = int(payload["rfqId"])
        mm = str(payload["mm"]).lower()
        price = int(payload["price"])
        deadline = int(payload["deadline"])
        signature = bytes.fromhex(str(payload["sig"]).removeprefix("0x"))
        claimed_chain = int(payload["chainId"])
    except (KeyError, TypeError, ValueError) as e:
        raise QuoteError(f"malformed quote: {e}") from e

    # The chain id goes into the signed digest, so a mismatch would let a quote be
    # replayed against a same-address deployment on another chain.
    if claimed_chain != chain_id:
        raise QuoteError("chainId does not match the enclave's chain")

    seller, yt_amount, min_price, _settle_by, is_open = chain.read_rfq(rfq, rfq_id)
    if not is_open:
        raise QuoteError("rfq not open")
    if seller.lower() == mm:
        raise QuoteError("seller cannot quote on its own RFQ")

    now = chain.latest_block_timestamp()
    if deadline <= now + MIN_QUOTE_DEADLINE_SLACK:
        raise QuoteError("quote expires too soon to settle")
    if price < min_price:
        raise QuoteError("below the seller's reserve")
    if price >= yt_amount:
        raise QuoteError("premium must be below the YT notional")

    digest = quote_digest(chain_id, rfq, rfq_id, mm, yt_amount, price, deadline)
    if recover(digest, signature) != mm:
        raise QuoteError("signature does not recover to the claimed market maker")

    return Quote(rfq=rfq, rfq_id=rfq_id, mm=mm, price=price, deadline=deadline), yt_amount


def store(quote: Quote) -> int:
    """Add a quote to the book, returning how many market makers now quote this RFQ."""
    key = (quote.rfq, quote.rfq_id)
    with _book_lock:
        book = _book.setdefault(key, {})
        if quote.mm not in book and len(book) >= MAX_QUOTES_PER_RFQ:
            raise QuoteError("too many market makers on this RFQ")
        book[quote.mm] = quote
        return len(book)


def quotes_for(rfq: str, rfq_id: int) -> list[Quote]:
    with _book_lock:
        return list(_book.get((rfq.lower(), rfq_id), {}).values())


def drop(rfq: str, rfq_id: int) -> None:
    """Forget a settled RFQ's book."""
    with _book_lock:
        _book.pop((rfq.lower(), rfq_id), None)


def book_size() -> tuple[int, int]:
    """(rfqs tracked, quotes held) — counts only; prices never leave the enclave."""
    with _book_lock:
        return len(_book), sum(len(b) for b in _book.values())


def reset() -> None:
    """Clear the book. Tests only."""
    with _book_lock:
        _book.clear()


def premium_usd_1e6(price: int, xrp_usd_1e18: int) -> int:
    """FXRP premium (6dp, ~1:1 with XRP) valued in USD at 6dp."""
    return price * xrp_usd_1e18 // 10**18


def choose_winner(candidates: list[Quote], yt_amount: int, min_price: int, fxrp: str, rfq: str) -> tuple[Quote, int]:
    """Best execution: highest payable price at or above the reserve, inside the USD band.

    Ties at equal price are broken with Flare Secure RNG so no market maker can
    win them by construction. Returns the winner and its premium in USD (6dp).
    """
    xrp_usd = chain.xrp_usd_1e18()  # the premium is bounded in real USD terms, not just token units
    # Never let the USD cap brick a high reserve the seller deliberately set.
    cap = max(MAX_PREMIUM_USD_1E6, 2 * premium_usd_1e6(min_price, xrp_usd))

    eligible = []
    for q in candidates:
        usd = premium_usd_1e6(q.price, xrp_usd)
        if min_price <= q.price < yt_amount and MIN_PREMIUM_USD_1E6 <= usd <= cap:
            eligible.append(q)
    if not eligible:
        raise QuoteError("no eligible quote (at/above reserve and within the FTSO USD band)")

    rnd = chain.secure_random()
    ordered = sorted(eligible, key=lambda q: (-q.price, rnd ^ int(q.mm, 16)))
    for q in ordered:  # best price first; the first solvent quote wins, so reads stay bounded
        if chain.mm_can_pay(fxrp, rfq, q.mm, q.price):
            return q, premium_usd_1e6(q.price, xrp_usd)
    raise QuoteError("no solvent quote within band at or above the reserve")
