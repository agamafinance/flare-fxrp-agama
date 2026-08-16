"""Wire types and the handler registry.

--- DO NOT MODIFY: infrastructure code. ---

Field names and encodings are fixed by docs/extension-contract.md §4.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from typing import Any, Callable, Iterable, Optional

from .encoding import string_to_bytes32_hex

# A handler receives the raw originalMessage hex and returns
# (data_hex_or_None, status, error_message_or_None).
HandlerFunc = Callable[[str], "tuple[Optional[str], int, Optional[str]]"]

# Returns any JSON-serializable snapshot of extension state.
ReportStateFunc = Callable[[], Any]

# Called once at startup to register handlers.
RegisterFunc = Callable[["Framework"], None]

EMPTY_BYTES32 = string_to_bytes32_hex("")


@dataclass
class ActionData:
    """The `data` field of an Action (contract §4.2)."""

    id: str
    type: str
    submission_tag: str
    message: str  # hex-encoded UTF-8 JSON that decodes to a DataFixed


@dataclass
class Action:
    """Request body of POST /action (contract §4.1)."""

    data: ActionData
    additional_variable_messages: list[str] = field(default_factory=list)
    timestamps: list[int] = field(default_factory=list)
    additional_action_data: str = "0x"
    signatures: list[str] = field(default_factory=list)


@dataclass
class DataFixed:
    """Decoded from ActionData.message (contract §4.3)."""

    instruction_id: str
    op_type: str
    op_command: str
    tee_id: str = ""
    timestamp: int = 0
    reward_epoch_id: int = 0
    cosigners: list[str] = field(default_factory=list)
    cosigners_threshold: int = 0
    original_message: str = "0x"
    additional_fixed_message: str = "0x"


@dataclass
class ActionResult:
    """Response body of POST /action (contract §4.4)."""

    id: str
    submission_tag: str
    status: int
    op_type: str
    op_command: str
    version: str  # plain version string, NOT bytes32 — see contract §4.4
    log: Optional[str] = None
    additional_result_status: Optional[str] = None
    data: Optional[str] = None

    def to_dict(self) -> dict[str, Any]:
        """Serialize exactly as tee-node's Go ActionResult struct does.

        Every field is always present. tee-node declares `Data` and
        `AdditionalResultStatus` as hexutil.Bytes with no omitempty, so they
        marshal as "0x" rather than being omitted when empty; `Log` is a plain
        string and is likewise always emitted. Key order matches the Go struct.
        """
        return {
            "id": self.id,
            "submissionTag": self.submission_tag,
            "status": self.status,
            "log": self.log or "",
            "opType": self.op_type,
            "opCommand": self.op_command,
            "additionalResultStatus": self.additional_result_status or "0x",
            "version": self.version,
            "data": self.data or "0x",
        }


@dataclass
class StateResponse:
    """Response body of GET /state (contract §4.5).

    Note the asymmetry with ActionResult: stateVersion IS bytes32 hex.
    """

    state_version: str
    state: Any

    def to_dict(self) -> dict[str, Any]:
        return {"stateVersion": self.state_version, "state": self.state}


# The two channels an action can arrive on. A direct action is posted by anyone
# to the proxy's public /direct endpoint; an on-chain instruction is emitted by
# the extension's own contract and delivered through the proxy's main queue.
# These are NOT the same trust level, and a handler must say which it accepts:
# a settlement reachable over /direct turns the sealed book into a public read
# API (an unauthenticated caller gets the winner, the price, and a TEE signature).
CHANNEL_DIRECT = "direct"
CHANNEL_ONCHAIN = "onchain"


class ChannelError(Exception):
    """Raised when an action arrives on a channel its handler does not accept."""


class Framework:
    """Maps (opType, opCommand) bytes32 pairs to handlers (contract §5)."""

    def __init__(self) -> None:
        self._handlers: list[tuple[str, str, HandlerFunc, frozenset[str]]] = []

    def handle(
        self,
        op_type: str,
        op_command: str,
        handler: HandlerFunc,
        channels: Iterable[str] = (CHANNEL_DIRECT, CHANNEL_ONCHAIN),
    ) -> None:
        """Register a handler.

        Both identifiers are given as plain strings and converted to bytes32.
        Pass "" for op_command to make this the default for every command under
        op_type. `channels` restricts which arrival channel is accepted; the
        default accepts both, so a handler that must not be publicly callable
        has to opt out explicitly.
        """
        self._handlers.append(
            (
                string_to_bytes32_hex(op_type),
                string_to_bytes32_hex(op_command),
                handler,
                frozenset(channels),
            )
        )

    def lookup(self, op_type: str, op_command: str) -> Optional[HandlerFunc]:
        """Exact (opType, opCommand) match first, then the opCommand wildcard."""
        entry = self._lookup_entry(op_type, op_command)
        return entry[0] if entry else None

    def lookup_for_channel(
        self, op_type: str, op_command: str, channel: str
    ) -> Optional[HandlerFunc]:
        """Like `lookup`, but reject a handler that does not accept `channel`.

        Returns the handler when the op pair is registered and the channel is
        allowed; raises ChannelError when the op pair exists but the channel is
        not; returns None when there is no handler at all.
        """
        entry = self._lookup_entry(op_type, op_command)
        if entry is None:
            return None
        handler, channels = entry
        if channel not in channels:
            raise ChannelError(
                f"op ({_normalize(op_type)}, {_normalize(op_command)}) "
                f"is not accepted on the {channel} channel"
            )
        return handler

    def _lookup_entry(
        self, op_type: str, op_command: str
    ) -> Optional[tuple[HandlerFunc, frozenset[str]]]:
        op_type = _normalize(op_type)
        op_command = _normalize(op_command)

        for reg_type, reg_cmd, handler, channels in self._handlers:
            if reg_type == op_type and reg_cmd == op_command:
                return handler, channels
        for reg_type, reg_cmd, handler, channels in self._handlers:
            if reg_type == op_type and reg_cmd == EMPTY_BYTES32:
                return handler, channels
        return None


def _normalize(h: str) -> str:
    """Lowercase and 0x-prefix a hex identifier so comparisons are stable."""
    if not h:
        return EMPTY_BYTES32
    h = h.lower()
    if not h.startswith("0x"):
        h = "0x" + h
    return h


def parse_action(raw: dict[str, Any]) -> Action:
    data_raw = raw["data"]
    return Action(
        data=ActionData(
            id=data_raw["id"],
            type=data_raw.get("type", ""),
            submission_tag=data_raw.get("submissionTag", ""),
            message=data_raw["message"],
        ),
        additional_variable_messages=raw.get("additionalVariableMessages") or [],
        timestamps=raw.get("timestamps") or [],
        additional_action_data=raw.get("additionalActionData") or "0x",
        signatures=raw.get("signatures") or [],
    )


# ActionData.type values (tee-node pkg/types/actions.go).
INSTRUCTION_ACTION = "instruction"
DIRECT_ACTION = "direct"


def parse_direct_instruction(raw: dict[str, Any]) -> DataFixed:
    """Adapt a DirectInstruction into the DataFixed the handler contract expects.

    A direct action reaches the extension as {"opType", "opCommand", "message"} —
    the DirectInstruction tee-node received on POST /direct, forwarded verbatim.
    There is no instruction id, no cosigners and no timestamp: nothing on chain
    triggered it. The payload lives under `message`, not `originalMessage`.
    """
    return DataFixed(
        instruction_id="",
        op_type=raw["opType"],
        op_command=raw.get("opCommand", ""),
        original_message=raw.get("message") or "0x",
    )


def parse_data_fixed(raw: dict[str, Any]) -> DataFixed:
    return DataFixed(
        instruction_id=raw.get("instructionId", ""),
        op_type=raw["opType"],
        op_command=raw.get("opCommand", ""),
        tee_id=raw.get("teeId", ""),
        timestamp=raw.get("timestamp", 0),
        reward_epoch_id=raw.get("rewardEpochId", 0),
        cosigners=raw.get("cosigners") or [],
        cosigners_threshold=raw.get("cosignersThreshold", 0),
        original_message=raw.get("originalMessage") or "0x",
        additional_fixed_message=raw.get("additionalFixedMessage") or "0x",
    )
