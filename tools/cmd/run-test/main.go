// run-test drives one full confidential RFQ against a deployed extension:
// open an RFQ on chain, submit two sealed quotes straight to the TEE proxy
// (they never touch the chain), ask the enclave to settle, then relay the
// signed winning settlement back on chain and check who was paid.
package main

import (
	"bytes"
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"math/big"
	"net/http"
	"strings"
	"time"

	"extension-scaffold/tools/pkg/configs"
	"extension-scaffold/tools/pkg/fccutils"
	"extension-scaffold/tools/pkg/support"
	instrutils "extension-scaffold/tools/pkg/utils"

	"github.com/ethereum/go-ethereum/accounts/abi"
	"github.com/ethereum/go-ethereum/common"
	"github.com/ethereum/go-ethereum/crypto"
	"github.com/flare-foundation/go-flare-common/pkg/logger"
	"github.com/pkg/errors"
)

const (
	opTypeRFQ     = "RFQ"
	opCommandQuot = "QUOTE"
	// The RFQ terms used by the test. Amounts are in the tokens' own units.
	ytAmount = 100_000_000 // 100 YT at 6dp
	reserve  = 2_000_000   // 2 FXRP
	lowBid   = 4_000_000   // 4 FXRP
	highBid  = 6_000_000   // 6 FXRP — this one must win
)

// directAction is the body the proxy accepts on /direct: the same (opType,
// opCommand, message) triple an on-chain instruction carries.
type directAction struct {
	OPType    string `json:"opType"`
	OPCommand string `json:"opCommand"`
	Message   string `json:"message"`
}

func bytes32(s string) string {
	b := make([]byte, 32)
	copy(b, s)
	return "0x" + common.Bytes2Hex(b)
}

func main() {
	af := flag.String("a", configs.AddressesFile, "file with deployed addresses")
	cf := flag.String("c", configs.ChainNodeURL, "chain node url")
	pf := flag.String("p", configs.ExtensionProxyURL, "extension proxy url")
	instructionSenderF := flag.String("instructionSender", "", "instructionSender (RFQ) address")
	teeF := flag.String("tee", "", "TEE machine address from the proxy /info (optional: sets it on the RFQ)")
	apiKeyF := flag.String("apiKey", "", "DIRECT_API_KEY if the proxy requires one for /direct")
	flag.Parse()

	rfqAddress := common.HexToAddress(*instructionSenderF)

	s, err := support.DefaultSupport(*af, *cf)
	if err != nil {
		fccutils.FatalWithCause(err)
	}
	seller := crypto.PubkeyToAddress(s.Prv.PublicKey)

	// --- 1. Bind the contract to its extension and its TEE -------------------
	logger.Infof("Setting extension ID on the RFQ...")
	if err := instrutils.SetExtensionId(s, rfqAddress); err != nil {
		if strings.Contains(err.Error(), "already set") {
			logger.Infof("Extension ID already set, continuing")
		} else {
			fccutils.FatalWithCause(errors.Errorf(
				"setExtensionId failed — did pre-build.sh complete? Error: %s", err))
		}
	}
	if *teeF != "" {
		logger.Infof("Registering TEE machine %s on the RFQ...", *teeF)
		if err := instrutils.SetTeeAddress(s, rfqAddress, common.HexToAddress(*teeF)); err != nil {
			fccutils.FatalWithCause(err)
		}
	}

	// --- 2. Open an RFQ: the seller escrows YT and sets a reserve -------------
	fxrp, yt, err := instrutils.TokenAddresses()
	if err != nil {
		fccutils.FatalWithCause(err)
	}
	logger.Infof("Approving %d YT to the RFQ...", ytAmount)
	if err := instrutils.TokenApprove(s, yt, rfqAddress, big.NewInt(ytAmount)); err != nil {
		fccutils.FatalWithCause(err)
	}
	rfqID, err := instrutils.OpenRfq(s, rfqAddress, big.NewInt(ytAmount), big.NewInt(reserve))
	if err != nil {
		fccutils.FatalWithCause(err)
	}
	logger.Infof("RFQ %s open (seller %s, reserve %d)", rfqID, seller.Hex(), reserve)

	// --- 3. Two sealed quotes, straight to the enclave ------------------------
	// Both are signed by the same key here (the tooling key doubles as the market
	// maker), so the higher price must win on price alone. A production run has
	// one key per market maker; the enclave authenticates each independently.
	deadline := time.Now().Add(time.Hour).Unix()
	for _, price := range []int64{lowBid, highBid} {
		actionID, err := submitQuote(s, *pf, *apiKeyF, rfqAddress, rfqID, seller, price, deadline)
		if err != nil {
			fccutils.FatalWithCause(errors.Errorf("submitting the %d quote: %s", price, err))
		}
		// The proxy accepts the action before the enclave has judged the quote, so
		// poll the result: a quote the enclave rejects must fail here, not silently
		// go missing from the auction.
		status, log, err := directResult(*pf, actionID)
		if err != nil {
			// Two things produce no stored result: a quote the enclave refused (its
			// reason stays inside the enclave, in the extension log), and a TEE the
			// proxy will not publish for — "invalid teeID" until post-build.sh has
			// registered this machine on chain.
			fccutils.FatalWithCause(errors.Errorf(
				"no result for the %d quote (%s) — either the enclave rejected it (see the extension log) "+
					"or this TEE is not registered yet (run post-build.sh)", price, err))
		}
		if status != 1 {
			fccutils.FatalWithCause(errors.Errorf("the enclave rejected the %d quote: %s", price, log))
		}
		logger.Infof("Quote %d accepted by the enclave (never touched the chain)", price)
	}

	// --- 4. Ask the enclave to run best execution -----------------------------
	logger.Infof("Requesting settlement...")
	instructionID, err := instrutils.RequestSettlement(s, rfqAddress, rfqID)
	if err != nil {
		fccutils.FatalWithCause(err)
	}
	logger.Infof("Instruction sent. ID: %s", instructionID.Hex())
	time.Sleep(5 * time.Second)

	resp, err := fccutils.ActionResult(*pf, instructionID)
	if err != nil {
		fccutils.FatalWithCause(err)
	}
	result := resp.Result
	if result.Status == 0 {
		fccutils.FatalWithCause(errors.Errorf("the enclave refused to settle: %s", result.Log))
	}
	if result.Status == 2 {
		fccutils.FatalWithCause(errors.New("settlement still pending after polling"))
	}
	if len(resp.Signature) == 0 {
		fccutils.FatalWithCause(errors.New("no TEE signature on the result — is the node registered?"))
	}

	winner, price, err := decodeSettlement(result.Data)
	if err != nil {
		fccutils.FatalWithCause(err)
	}
	logger.Infof("Enclave signed: winner %s at %d", winner.Hex(), price)
	if price.Int64() != highBid {
		fccutils.FatalWithCause(errors.Errorf("best execution failed: expected %d, got %s", highBid, price))
	}

	// --- 5. Relay it. The contract verifies the signature before moving funds --
	txHash, err := instrutils.Settle(
		s, rfqAddress, result.Data, result.ID, string(result.SubmissionTag), result.Status, resp.Signature,
	)
	if err != nil {
		fccutils.FatalWithCause(err)
	}
	logger.Infof("Settled on chain: %s", txHash.Hex())
	logger.Infof("FXRP %s paid the seller; the losing quote never left the enclave.", fxrp.Hex())
	logger.Infof("All tests passed.")
}

// directResult polls a direct action's result. Direct actions are tagged "submit"
// while /action/result defaults to "threshold", so the tag has to be explicit or
// every lookup 404s on an action that completed fine.
func directResult(proxyURL string, actionID common.Hash) (uint8, string, error) {
	url := fmt.Sprintf("%s/action/result/%s?submissionTag=submit", strings.TrimRight(proxyURL, "/"), actionID.Hex())
	var lastErr error
	for range 15 {
		resp, err := http.Get(url)
		if err != nil {
			lastErr = err
		} else {
			body, _ := io.ReadAll(resp.Body)
			resp.Body.Close()
			if resp.StatusCode == http.StatusOK {
				var parsed struct {
					Result struct {
						Status uint8  `json:"status"`
						Log    string `json:"log"`
					} `json:"result"`
				}
				if err := json.Unmarshal(body, &parsed); err != nil {
					return 0, "", errors.Errorf("decoding the result: %s", err)
				}
				return parsed.Result.Status, parsed.Result.Log, nil
			}
			lastErr = errors.Errorf("proxy returned %d: %s", resp.StatusCode, strings.TrimSpace(string(body)))
		}
		time.Sleep(2 * time.Second)
	}
	return 0, "", lastErr
}

// submitQuote signs a quote the way a market maker does and posts it to the
// proxy's /direct endpoint, so the price is only ever seen inside the enclave.
func submitQuote(
	s *support.Support,
	proxyURL, apiKey string,
	rfq common.Address,
	rfqID *big.Int,
	mm common.Address,
	price, deadline int64,
) (common.Hash, error) {
	digest, err := quoteDigest(s.ChainID, rfq, rfqID, mm, big.NewInt(ytAmount), big.NewInt(price), big.NewInt(deadline))
	if err != nil {
		return common.Hash{}, err
	}
	signature, err := crypto.Sign(digest, s.Prv)
	if err != nil {
		return common.Hash{}, errors.Errorf("signing the quote: %s", err)
	}

	quote, err := json.Marshal(map[string]any{
		"rfq":      strings.ToLower(rfq.Hex()),
		"chainId":  s.ChainID.Int64(),
		"rfqId":    rfqID.Int64(),
		"mm":       strings.ToLower(mm.Hex()),
		"price":    price,
		"deadline": deadline,
		"sig":      "0x" + common.Bytes2Hex(signature),
	})
	if err != nil {
		return common.Hash{}, err
	}

	body, err := json.Marshal(directAction{
		OPType:    bytes32(opTypeRFQ),
		OPCommand: bytes32(opCommandQuot),
		Message:   "0x" + common.Bytes2Hex(quote),
	})
	if err != nil {
		return common.Hash{}, err
	}

	req, err := http.NewRequest(http.MethodPost, strings.TrimRight(proxyURL, "/")+"/direct", bytes.NewReader(body))
	if err != nil {
		return common.Hash{}, err
	}
	req.Header.Set("Content-Type", "application/json")
	if apiKey != "" {
		req.Header.Set("X-API-Key", apiKey)
	}

	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return common.Hash{}, errors.Errorf("posting to the proxy: %s", err)
	}
	defer resp.Body.Close()
	payload, _ := io.ReadAll(resp.Body)
	if resp.StatusCode != http.StatusOK {
		return common.Hash{}, errors.Errorf("proxy returned %d: %s", resp.StatusCode, string(payload))
	}

	// The proxy echoes the queued action; its id is what the result is keyed by.
	var queued struct {
		Data struct {
			ID common.Hash `json:"id"`
		} `json:"data"`
	}
	if err := json.Unmarshal(payload, &queued); err != nil {
		return common.Hash{}, errors.Errorf("decoding the queued action: %s", err)
	}
	return queued.Data.ID, nil
}

// quoteDigest mirrors AgamaRfqInstructionSender.quoteDigest and the extension's
// own encoding. The Solidity test replays a vector from the Python side, so all
// three stay pinned to the same preimage.
func quoteDigest(
	chainID *big.Int,
	rfq common.Address,
	rfqID *big.Int,
	mm common.Address,
	ytAmt, price, deadline *big.Int,
) ([]byte, error) {
	stringT, _ := abi.NewType("string", "", nil)
	uintT, _ := abi.NewType("uint256", "", nil)
	addrT, _ := abi.NewType("address", "", nil)
	args := abi.Arguments{
		{Type: stringT}, {Type: uintT}, {Type: addrT}, {Type: uintT},
		{Type: addrT}, {Type: uintT}, {Type: uintT}, {Type: uintT},
	}
	packed, err := args.Pack("AnchorQuote", chainID, rfq, rfqID, mm, ytAmt, price, deadline)
	if err != nil {
		return nil, errors.Errorf("packing the quote digest: %s", err)
	}
	return crypto.Keccak256(packed), nil
}

// decodeSettlement reads the winner and price out of the enclave's ActionResult.Data.
func decodeSettlement(data []byte) (common.Address, *big.Int, error) {
	uintT, _ := abi.NewType("uint256", "", nil)
	addrT, _ := abi.NewType("address", "", nil)
	args := abi.Arguments{
		{Type: addrT}, {Type: uintT}, {Type: addrT}, {Type: addrT},
		{Type: uintT}, {Type: uintT}, {Type: uintT},
	}
	values, err := args.Unpack(data)
	if err != nil {
		return common.Address{}, nil, errors.Errorf("decoding the settlement: %s", err)
	}
	if len(values) != 7 {
		return common.Address{}, nil, errors.Errorf("settlement has %d fields, expected 7", len(values))
	}
	winner, ok := values[3].(common.Address)
	if !ok {
		return common.Address{}, nil, errors.New("settlement winner is not an address")
	}
	price, ok := values[5].(*big.Int)
	if !ok {
		return common.Address{}, nil, errors.New("settlement price is not a uint256")
	}
	return winner, price, nil
}
