"""The confidential RFQ handlers.

The chain is stubbed (see tests/helpers.py): these tests pin the extension's own
guarantees — a quote is only accepted if its market maker signed it, best
execution respects the seller's reserve and the FTSO USD band, and only the
winner ever leaves the enclave.
"""

import json

from app import chain, handlers, quotes
from base.encoding import bytes_to_hex, hex_to_bytes
from tests.helpers import (
    DEADLINE,
    MIN_PRICE,
    MM1,
    MM2,
    NOW,
    RFQ,
    SELLER,
    YT_AMOUNT,
    addr,
    decode_settlement,
    quote_msg,
    settle_msg,
    signed_quote,
)


class TestQuote:
    def test_authentic_quote_is_accepted(self):
        data, status, err = handlers.handle_quote(quote_msg(signed_quote(MM1, 6_000_000)))
        assert (status, err) == (1, None)
        body = json.loads(hex_to_bytes(data))
        assert body == {"accepted": True, "rfqId": 1, "quotesHeld": 1}

    def test_response_never_carries_a_price(self):
        _ = handlers.handle_quote(quote_msg(signed_quote(MM1, 6_000_000)))
        data, _s, _e = handlers.handle_quote(quote_msg(signed_quote(MM2, 4_000_000)))
        assert "4000000" not in hex_to_bytes(data).decode()

    def test_quote_forged_for_another_mm_is_rejected(self):
        # MM2 signs, but claims to be MM1
        payload = signed_quote(MM2, 6_000_000, mm=addr(MM1))
        _data, status, err = handlers.handle_quote(quote_msg(payload))
        assert status == 0
        assert "does not recover" in err

    def test_below_reserve_is_rejected(self):
        _data, status, err = handlers.handle_quote(quote_msg(signed_quote(MM1, MIN_PRICE - 1)))
        assert (status, err) == (0, "below the seller's reserve")

    def test_wrong_chain_is_rejected(self):
        _data, status, err = handlers.handle_quote(quote_msg(signed_quote(MM1, 6_000_000, chain_id=1)))
        assert status == 0
        assert "chainId" in err

    def test_quote_expiring_before_settlement_is_rejected(self):
        payload = signed_quote(MM1, 6_000_000, deadline=NOW + 10)
        _data, status, err = handlers.handle_quote(quote_msg(payload))
        assert (status, err) == (0, "quote expires too soon to settle")

    def test_seller_cannot_quote_its_own_rfq(self):
        _data, status, err = handlers.handle_quote(quote_msg(signed_quote(SELLER, 6_000_000)))
        assert (status, err) == (0, "seller cannot quote on its own RFQ")

    def test_a_market_maker_holds_one_live_quote(self):
        handlers.handle_quote(quote_msg(signed_quote(MM1, 4_000_000)))
        data, _s, _e = handlers.handle_quote(quote_msg(signed_quote(MM1, 6_000_000)))
        assert json.loads(hex_to_bytes(data))["quotesHeld"] == 1
        assert quotes.quotes_for(RFQ, 1)[0].price == 6_000_000

    def test_malformed_payload_is_an_error_not_a_crash(self):
        _data, status, err = handlers.handle_quote(bytes_to_hex(b"not json"))
        assert status == 0 and "JSON" in err


class TestSettle:
    def test_best_price_wins_and_only_the_winner_comes_out(self):
        handlers.handle_quote(quote_msg(signed_quote(MM1, 4_000_000)))
        handlers.handle_quote(quote_msg(signed_quote(MM2, 6_000_000)))

        data, status, err = handlers.handle_settle(settle_msg())
        assert (status, err) == (1, None)

        contract, rfq_id, seller, winner, yt_amount, price, deadline = decode_settlement(data)
        assert contract.lower() == RFQ
        assert rfq_id == 1
        assert seller.lower() == addr(SELLER)
        assert winner.lower() == addr(MM2)
        assert (yt_amount, price, deadline) == (YT_AMOUNT, 6_000_000, DEADLINE)
        # the losing quote is nowhere in the output
        assert addr(MM1) not in data.lower()

    def test_signing_does_not_clear_the_book(self):
        # A signed settlement is not a settled one: if the relayer never submits it,
        # the RFQ must still be settleable on a second attempt.
        handlers.handle_quote(quote_msg(signed_quote(MM1, 6_000_000)))
        handlers.handle_settle(settle_msg())
        assert len(quotes.quotes_for(RFQ, 1)) == 1

        data, status, err = handlers.handle_settle(settle_msg())
        assert (status, err) == (1, None)
        assert decode_settlement(data)[3].lower() == addr(MM1)

    def test_a_closed_rfq_drops_the_book(self, monkeypatch):
        handlers.handle_quote(quote_msg(signed_quote(MM1, 6_000_000)))
        monkeypatch.setattr(
            chain, "read_rfq", lambda _r, _i: (addr(SELLER), YT_AMOUNT, MIN_PRICE, NOW + 900, False)
        )
        handlers.handle_settle(settle_msg())
        assert quotes.quotes_for(RFQ, 1) == []

    def test_no_quotes_is_an_error(self):
        _data, status, err = handlers.handle_settle(settle_msg())
        assert (status, err) == (0, "no quotes held for this rfq")

    def test_an_insolvent_winner_is_skipped(self, monkeypatch):
        handlers.handle_quote(quote_msg(signed_quote(MM1, 4_000_000)))
        handlers.handle_quote(quote_msg(signed_quote(MM2, 6_000_000)))
        monkeypatch.setattr(chain, "mm_can_pay", lambda _f, _r, mm, _p: mm != addr(MM2))

        data, status, _err = handlers.handle_settle(settle_msg())
        assert status == 1
        assert decode_settlement(data)[3].lower() == addr(MM1)

    def test_a_premium_above_the_usd_band_is_rejected(self):
        # 60 FXRP at $0.50 is $30, over the $10 per-settlement cap
        handlers.handle_quote(quote_msg(signed_quote(MM1, 60_000_000)))
        _data, status, err = handlers.handle_settle(settle_msg())
        assert status == 0 and "FTSO USD band" in err

    def test_expired_quotes_do_not_settle(self, monkeypatch):
        handlers.handle_quote(quote_msg(signed_quote(MM1, 6_000_000)))
        monkeypatch.setattr(chain, "latest_block_timestamp", lambda: DEADLINE + 1)
        _data, status, err = handlers.handle_settle(settle_msg())
        assert (status, err) == (0, "every held quote expires too soon to settle")

    def test_a_quote_expiring_within_the_settle_slack_is_not_signed(self, monkeypatch):
        # Accepted at ingest (deadline is well beyond now + slack), but by the time
        # settlement runs the clock has advanced so the quote no longer outlives
        # now + slack. Signing it would produce a settlement that reverts on chain
        # with "expired" before the relayer can land it, so it must be dropped.
        handlers.handle_quote(quote_msg(signed_quote(MM1, 6_000_000, deadline=NOW + 200)))
        monkeypatch.setattr(chain, "latest_block_timestamp", lambda: NOW + 180)
        _data, status, err = handlers.handle_settle(settle_msg())
        assert (status, err) == (0, "every held quote expires too soon to settle")

    def test_a_quote_with_a_full_slack_margin_still_settles(self, monkeypatch):
        # The mirror of the above: a quote that clears now + slack at settle time
        # must go through, so the tightened check does not reject healthy quotes.
        handlers.handle_quote(quote_msg(signed_quote(MM1, 6_000_000, deadline=NOW + 500)))
        monkeypatch.setattr(chain, "latest_block_timestamp", lambda: NOW + 100)
        data, status, err = handlers.handle_settle(settle_msg())
        assert (status, err) == (1, None)
        assert decode_settlement(data)[3].lower() == addr(MM1)

    def test_a_closed_rfq_does_not_settle(self, monkeypatch):
        handlers.handle_quote(quote_msg(signed_quote(MM1, 6_000_000)))
        monkeypatch.setattr(
            chain, "read_rfq", lambda _r, _i: (addr(SELLER), YT_AMOUNT, MIN_PRICE, NOW + 900, False)
        )
        _data, status, err = handlers.handle_settle(settle_msg())
        assert (status, err) == (0, "rfq not open")


class TestState:
    def test_state_reports_counts_not_quotes(self):
        handlers.handle_quote(quote_msg(signed_quote(MM1, 6_000_000)))
        handlers.handle_quote(quote_msg(signed_quote(MM1, MIN_PRICE - 1)))
        state = handlers.report_state()
        assert state["quotesAccepted"] == 1
        assert state["quotesRejected"] == 1
        assert state["quotesHeld"] == 1
        assert "6000000" not in json.dumps(state)


class TestBookBounds:
    """Enclave memory is bounded on two axes: quotes per RFQ, and RFQs tracked.
    Both matter because /direct is unauthenticated and a quote costs nothing."""

    def _q(self, rfq_id, deadline, mm="0xmm"):
        return quotes.Quote(rfq=RFQ, rfq_id=rfq_id, mm=mm, price=6_000_000, deadline=deadline)

    def test_a_thirty_third_market_maker_is_refused(self):
        for i in range(quotes.MAX_QUOTES_PER_RFQ):
            quotes.store(self._q(1, NOW + 3600, mm=f"0x{i:040x}"))
        try:
            quotes.store(self._q(1, NOW + 3600, mm="0xdeadbeef"))
            assert False, "expected the 33rd market maker to be refused"
        except quotes.QuoteError as e:
            assert "too many market makers" in str(e)

    def test_a_new_rfq_evicts_the_stalest_when_the_book_is_full(self, monkeypatch):
        monkeypatch.setattr(quotes, "MAX_RFQS_TRACKED", 3)
        # three RFQs whose quotes expire at increasing times
        quotes.store(self._q(rfq_id=1, deadline=NOW + 100))
        quotes.store(self._q(rfq_id=2, deadline=NOW + 200))
        quotes.store(self._q(rfq_id=3, deadline=NOW + 300))
        # a fourth, fresher than the stalest (rfq 1) → rfq 1 is evicted
        quotes.store(self._q(rfq_id=4, deadline=NOW + 400))
        held = {rid for (_rfq, rid) in quotes._book}
        assert held == {2, 3, 4}, held

    def test_a_stale_newcomer_is_refused_rather_than_evicting_a_fresher_book(self, monkeypatch):
        monkeypatch.setattr(quotes, "MAX_RFQS_TRACKED", 2)
        quotes.store(self._q(rfq_id=1, deadline=NOW + 500))
        quotes.store(self._q(rfq_id=2, deadline=NOW + 600))
        try:
            # expires sooner than every tracked RFQ → must not evict a fresher one
            quotes.store(self._q(rfq_id=3, deadline=NOW + 100))
            assert False, "expected the stale newcomer to be refused"
        except quotes.QuoteError as e:
            assert "too many RFQs tracked" in str(e)
        held = {rid for (_rfq, rid) in quotes._book}
        assert held == {1, 2}, held
