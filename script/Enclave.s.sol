// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import "forge-std/Script.sol";

interface IReg { function getContractAddressByName(string calldata) external view returns (address); }
interface IFtso { function getFeedById(bytes21) external view returns (uint256, int8, uint64); }
interface IRng { function getRandomNumber() external view returns (uint256, bool, uint256); }

/**
 * Enclave: simulates the Confidential Compute enclave that runs the YT RFQ matching.
 *
 * It receives the sealed market-maker quotes (here via env), picks best execution (highest price
 * for the seller), and signs the winning settlement with the enclave key. In production this exact
 * logic runs inside GCP Confidential Space (Intel TDX); the losing quotes never leave the enclave,
 * and the enclave key is sealed to the attested code. The signature it prints is what a relayer
 * submits to ConfidentialYtRfq.settle(...).
 *
 * Run (chainId comes from the RPC so the digest matches the target deployment):
 *   ENCLAVE_PK=0x.. RFQ=0x.. RFQ_ID=1 SELLER=0x.. YT_AMOUNT=1000000000 DEADLINE=<unix> \
 *   QUOTE_MMS=0xmm1,0xmm2 QUOTE_PRICES=12000000,9000000 \
 *   forge script script/Enclave.s.sol:Enclave --rpc-url coston2
 */
contract Enclave is Script {
    function run() external view {
        uint256 pk = vm.envUint("ENCLAVE_PK");
        address rfq = vm.envAddress("RFQ");
        uint256 rfqId = vm.envUint("RFQ_ID");
        address seller = vm.envAddress("SELLER");
        uint256 ytAmount = vm.envUint("YT_AMOUNT");
        uint256 deadline = vm.envUint("DEADLINE");
        address[] memory mms = vm.envAddress("QUOTE_MMS", ",");
        uint256[] memory prices = vm.envUint("QUOTE_PRICES", ",");

        // best execution: highest price wins; ties broken fairly by Flare Secure RNG
        (address winner, uint256 best) = _pickWinner(mms, prices);

        // oracle-aware: cross-check the winning quote against the live FTSO oracle (see _oracleAware)
        _oracleAware(best, ytAmount);

        bytes32 digest =
            keccak256(abi.encode("AnchorRFQ", block.chainid, rfq, rfqId, seller, winner, ytAmount, best, deadline));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);

        console2.log("== enclave signed the winning settlement ==");
        console2.log("winner (best MM)", winner);
        console2.log("price          ", best);
        // single parseable line for a relayer/front to consume
        console2.log(
            string.concat(
                "RESULT winner=",
                vm.toString(winner),
                " price=",
                vm.toString(best),
                " v=",
                vm.toString(uint256(v)),
                " r=",
                vm.toString(r),
                " s=",
                vm.toString(s)
            )
        );
    }

    /// Best execution with a fair tie-break: highest price wins; if several market makers tie at
    /// the best price, Flare's enshrined Secure RNG picks among them verifiably (no operator bias).
    function _pickWinner(address[] memory mms, uint256[] memory prices)
        internal view returns (address winner, uint256 best)
    {
        for (uint256 i; i < prices.length; i++) if (prices[i] > best) best = prices[i];
        uint256 ties;
        for (uint256 i; i < prices.length; i++) if (prices[i] == best) ties++;
        uint256 pick;
        if (ties > 1) {
            (uint256 rnd,,) = IRng(IReg(0xaD67FE66660Fb8dFE9d6b1b4240d8650e30F6019).getContractAddressByName("RandomNumberV2")).getRandomNumber();
            pick = rnd % ties;
            console2.log("tie at best price broken by Flare Secure RNG; ties =", ties);
        }
        uint256 seen;
        for (uint256 i; i < prices.length; i++) {
            if (prices[i] == best) { if (seen == pick) { winner = mms[i]; break; } seen++; }
        }
    }

    /// The enclave reads the live enshrined FTSO oracle to (1) reject economically absurd quotes
    /// (a YT premium must be positive and below the notional) and (2) express the premium in USD.
    function _oracleAware(uint256 best, uint256 ytAmount) internal view {
        require(best > 0 && best < ytAmount, "quote out of economic bound");
        IFtso ftso = IFtso(IReg(0xaD67FE66660Fb8dFE9d6b1b4240d8650e30F6019).getContractAddressByName("FtsoV2"));
        (uint256 pxv, int8 pxd,) = ftso.getFeedById(0x015852502f55534400000000000000000000000000);
        uint256 px1e18 = pxv * 1e18 / (10 ** uint256(uint8(pxd)));
        console2.log("FTSO XRP/USD (1e18)", px1e18);
        console2.log("premium in USD (1e18)", best * px1e18 / 1e6);
    }
}
