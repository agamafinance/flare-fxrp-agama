// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

/**
 * Minimal Flare Data Connector (FDC) "Payment" attestation types, matching the enshrined
 * FdcVerification interface. A Payment proof attests that a specific payment happened on an
 * external chain (e.g. an XRP transfer on the XRPL). Agama uses this to accept a native-XRP
 * deposit: the user pays XRP on the XRPL, the FDC attests it, and the proof is verified on chain.
 */
library Payment {
    struct RequestBody {
        bytes32 transactionId;
        uint256 inUtxo;
        uint256 utxo;
    }

    struct ResponseBody {
        uint64 blockNumber;
        uint64 blockTimestamp;
        bytes32 sourceAddressHash;
        bytes32 sourceAddressesRoot;
        bytes32 receivingAddressHash;
        bytes32 intendedReceivingAddressHash;
        int256 spentAmount;
        int256 intendedSpentAmount;
        int256 receivedAmount;
        int256 intendedReceivedAmount;
        bytes32 standardPaymentReference;
        bool oneToOne;
        uint8 status;
    }

    struct Response {
        bytes32 attestationType;
        bytes32 sourceId;
        uint64 votingRound;
        uint64 lowestUsedTimestamp;
        RequestBody requestBody;
        ResponseBody responseBody;
    }

    struct Proof {
        bytes32[] merkleProof;
        Response data;
    }
}

interface IFdcVerification {
    function verifyPayment(Payment.Proof calldata _proof) external view returns (bool);
}

interface IFdcRegistry {
    function getContractAddressByName(string calldata _name) external view returns (address);
}

interface IRelay {
    // finalized Merkle root for a protocol's voting round (FDC protocol id = 200)
    function merkleRoots(uint256 _protocolId, uint256 _votingRoundId) external view returns (bytes32);
}
