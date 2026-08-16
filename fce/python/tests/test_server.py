"""Server routing and wire format — docs/extension-contract.md §2, §4."""

import json

import pytest

from app import handlers
from app.config import VERSION
from base.encoding import bytes_to_hex, hex_to_bytes, string_to_bytes32_hex
from base.server import Server
from tests.helpers import MM1, RFQ, quote_msg, settle_msg, signed_quote


@pytest.fixture
def srv():
    return Server(0, 0, VERSION, handlers.register, handlers.report_state)


def a_quote(price=6_000_000):
    """A well-formed sealed quote, as raw bytes for the action's originalMessage."""
    return hex_to_bytes(quote_msg(signed_quote(MM1, price)))


def build_action(op_type="RFQ", op_command="QUOTE", original=b"", action_id=None):
    """Build a POST /action body in the exact shape tee-node sends."""
    data_fixed = {
        "instructionId": action_id or "0x" + "11" * 32,
        "teeId": "0x" + "22" * 20,
        "timestamp": 1700000000,
        "rewardEpochId": 42,
        "opType": string_to_bytes32_hex(op_type),
        "opCommand": string_to_bytes32_hex(op_command),
        "cosigners": [],
        "cosignersThreshold": 0,
        "originalMessage": bytes_to_hex(original),
        "additionalFixedMessage": "0x",
    }
    return json.dumps(
        {
            "data": {
                "id": action_id or "0x" + "11" * 32,
                "type": "instruction",
                "submissionTag": "submit",
                "message": bytes_to_hex(json.dumps(data_fixed).encode("utf-8")),
            },
            "additionalVariableMessages": [],
            "timestamps": [],
            "additionalActionData": "0x",
            "signatures": [],
        }
    ).encode("utf-8")


class TestRouting:
    def test_get_action_is_405(self, srv):
        assert srv.handle_request("GET", "/action", b"")[0] == 405

    def test_post_state_is_405(self, srv):
        assert srv.handle_request("POST", "/state", b"")[0] == 405

    def test_unknown_path_is_404(self, srv):
        assert srv.handle_request("GET", "/nope", b"")[0] == 404
        assert srv.handle_request("POST", "/nope", b"")[0] == 404

    def test_unknown_op_type_is_501(self, srv):
        status, body = srv.handle_request(
            "POST", "/action", build_action(op_type="NOPE")
        )
        assert status == 501
        assert body == "unsupported op type"

    def test_unknown_op_command_is_501(self, srv):
        status, _ = srv.handle_request(
            "POST", "/action", build_action(op_command="NOPE")
        )
        assert status == 501

    def test_query_string_is_ignored(self, srv):
        assert srv.handle_request("GET", "/state?verbose=1", b"")[0] == 200


class TestMalformedInput:
    def test_invalid_json_body_is_400(self, srv):
        assert srv.handle_request("POST", "/action", b"not json")[0] == 400

    def test_missing_data_field_is_400(self, srv):
        assert srv.handle_request("POST", "/action", b'{"foo":1}')[0] == 400

    def test_invalid_hex_message_is_400(self, srv):
        body = json.dumps(
            {"data": {"id": "0x1", "type": "instruction",
                      "submissionTag": "submit", "message": "0xZZ"}}
        ).encode()
        assert srv.handle_request("POST", "/action", body)[0] == 400

    def test_message_not_json_is_400(self, srv):
        body = json.dumps(
            {"data": {"id": "0x1", "type": "instruction",
                      "submissionTag": "submit",
                      "message": bytes_to_hex(b"not json")}}
        ).encode()
        assert srv.handle_request("POST", "/action", body)[0] == 400


class TestActionResultWireFormat:
    def test_success_shape(self, srv):
        status, body = srv.handle_request("POST", "/action", build_direct_action(original=a_quote()))

        assert status == 200
        assert body["status"] == 1
        assert body["log"] == "ok"
        assert body["opType"] == string_to_bytes32_hex("RFQ")
        assert body["opCommand"] == string_to_bytes32_hex("QUOTE")
        assert body["data"].startswith("0x")

    def test_version_is_plain_string_not_bytes32(self, srv):
        # Contract §4.4: tee-node declares `Version string`. The sign repo's
        # Python/TS ports hex-encode this and are wrong; this test pins it.
        _, body = srv.handle_request("POST", "/action", build_direct_action(original=a_quote()))

        assert body["version"] == "0.1.0"
        assert not body["version"].startswith("0x")

    def test_handler_error_is_http_200_with_status_0(self, srv):
        # Handler failure is signalled in the body, never by the HTTP status.
        status, body = srv.handle_request("POST", "/action", build_direct_action(original=b"not a quote"))

        assert status == 200
        assert body["status"] == 0
        assert body["log"].startswith("error: ")
        # Present as "0x", not omitted: the Go struct has no omitempty.
        assert body["data"] == "0x"

    def test_all_fields_always_present(self, srv):
        # tee-node's ActionResult has no omitempty tags, so every field appears
        # on the wire regardless of value. Verified against Go by the
        # conformance fixtures in testdata/conformance/.
        _, body = srv.handle_request("POST", "/action", build_direct_action(original=a_quote()))

        assert set(body) == {
            "id", "submissionTag", "status", "log", "opType",
            "opCommand", "additionalResultStatus", "version", "data",
        }
        assert body["additionalResultStatus"] == "0x"

    def test_echoes_id_and_submission_tag(self, srv):
        action_id = "0x" + "ab" * 32
        _, body = srv.handle_request(
            "POST", "/action", build_direct_action(original=a_quote(), action_id=action_id)
        )
        assert body["id"] == action_id
        assert body["submissionTag"] == "submit"

    def test_settle_abi_path(self, srv):
        # The on-chain instruction is ABI-encoded, not JSON — the other wire shape.
        srv.handle_request("POST", "/action", build_direct_action(original=a_quote()))
        _, body = srv.handle_request(
            "POST",
            "/action",
            build_action(op_command="SETTLE", original=hex_to_bytes(settle_msg())),
        )
        assert body["status"] == 1
        assert body["opCommand"] == string_to_bytes32_hex("SETTLE")
        assert len(hex_to_bytes(body["data"])) == 7 * 32


class TestStateWireFormat:
    def test_state_version_is_bytes32(self, srv):
        # Asymmetric with ActionResult.version by design — contract §4.5.
        status, body = srv.handle_request("GET", "/state", b"")
        assert status == 200
        assert body["stateVersion"] == string_to_bytes32_hex("0.1.0")
        assert len(body["stateVersion"]) == 66

    def test_state_reflects_handler_effects(self, srv):
        srv.handle_request("POST", "/action", build_direct_action(original=a_quote()))
        _, body = srv.handle_request("GET", "/state", b"")
        assert body["state"]["quotesAccepted"] == 1
        assert body["state"]["quotesHeld"] == 1
        # the book itself never appears in /state
        assert RFQ not in json.dumps(body["state"])


def build_direct_action(op_type="RFQ", op_command="QUOTE", original=b"", action_id=None):
    """Build a POST /action body in the shape tee-node forwards for a direct action.

    Not the same envelope as an instruction: the payload sits under `message`,
    and there is no instruction id, no cosigners, no timestamp.
    """
    direct = {
        "opType": string_to_bytes32_hex(op_type),
        "opCommand": string_to_bytes32_hex(op_command),
        "message": bytes_to_hex(original),
    }
    return json.dumps(
        {
            "data": {
                "id": action_id or "0x" + "33" * 32,
                "type": "direct",
                "submissionTag": "submit",
                "message": bytes_to_hex(json.dumps(direct).encode("utf-8")),
            },
            "additionalVariableMessages": [],
            "timestamps": [],
            "additionalActionData": "0x",
            "signatures": [],
        }
    ).encode("utf-8")


class TestDirectAction:
    """Sealed quotes arrive this way, so the envelope must be read as a
    DirectInstruction. Read as a DataFixed it parses cleanly and yields an empty
    payload — the handler would then reject every authentic quote."""

    def test_payload_reaches_the_handler(self, srv):
        status, body = srv.handle_request("POST", "/action", build_direct_action(original=a_quote()))
        assert status == 200
        assert body["status"] == 1, body["log"]
        assert json.loads(hex_to_bytes(body["data"]))["accepted"] is True

    def test_routing_still_applies(self, srv):
        status, _ = srv.handle_request(
            "POST", "/action", build_direct_action(op_command="NOPE", original=a_quote())
        )
        assert status == 501

    def test_a_direct_action_with_no_payload_is_a_handler_error(self, srv):
        _status, body = srv.handle_request("POST", "/action", build_direct_action(original=b""))
        assert body["status"] == 0


class TestChannelSeparation:
    """SETTLE reveals the winner and price and is signed by the TEE, so it must
    never be reachable over the public /direct endpoint — only as an on-chain
    instruction. QUOTE is the opposite: it must stay reachable over /direct so a
    quote never touches the chain."""

    def _settle(self, contract=RFQ):
        return hex_to_bytes(settle_msg(rfq_id=1, contract=contract))

    def test_settle_over_direct_is_refused_before_the_handler_runs(self, srv):
        # The exploit: an unauthenticated caller posts RFQ/SETTLE to /direct and
        # reads back the winner and price. It must be refused with 403, and the
        # body must carry no settlement data.
        status, body = srv.handle_request(
            "POST", "/action",
            build_direct_action(op_command="SETTLE", original=self._settle()),
        )
        assert status == 403
        assert "data" not in body or body.get("data") in (None, "0x")

    def test_settle_as_an_onchain_instruction_is_accepted(self, srv):
        # The same op pair, arriving through the main queue, must still route to
        # the handler — so the fix does not break real settlement.
        status, body = srv.handle_request(
            "POST", "/action",
            build_action(op_command="SETTLE", original=self._settle()),
        )
        assert status == 200  # handler ran; it may report status 0 (no quotes)

    def test_quote_over_direct_is_accepted(self, srv):
        status, body = srv.handle_request(
            "POST", "/action", build_direct_action(original=a_quote())
        )
        assert status == 200
        assert body["status"] == 1, body["log"]

    def test_quote_as_an_onchain_instruction_is_still_accepted(self, srv):
        # QUOTE is not channel-locked: an on-chain quote only makes the
        # submitter's own bid public and is harmless, so it must not be refused
        # (the recorded wire-contract fixtures exercise QUOTE as an instruction).
        status, body = srv.handle_request(
            "POST", "/action", build_action(op_command="QUOTE", original=a_quote())
        )
        assert status == 200
        assert body["status"] == 1, body["log"]
