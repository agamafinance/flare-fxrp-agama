package utils

import (
	"context"
	"math/big"
	"os"
	"strings"
	"time"

	"extension-scaffold/tools/pkg/contracts/agamarfq"
	"extension-scaffold/tools/pkg/support"

	"github.com/ethereum/go-ethereum/accounts/abi"
	"github.com/ethereum/go-ethereum/accounts/abi/bind"
	"github.com/ethereum/go-ethereum/common"
	"github.com/ethereum/go-ethereum/core/types"
	"github.com/pkg/errors"
)

// InstructionFee is the value forwarded to the registry with every instruction.
// The registry returns the unused remainder to the claimBackAddress.
var InstructionFee = big.NewInt(1000000)

// erc20ABI is the slice of ERC20 this tooling needs: escrow approvals and, on the
// demo token, a public mint. Declared inline so the tools module needs no extra
// generated bindings for a standard interface.
const erc20ABI = `[
 {"name":"approve","type":"function","stateMutability":"nonpayable","inputs":[{"type":"address"},{"type":"uint256"}],"outputs":[{"type":"bool"}]},
 {"name":"mint","type":"function","stateMutability":"nonpayable","inputs":[{"type":"address"},{"type":"uint256"}],"outputs":[]},
 {"name":"balanceOf","type":"function","stateMutability":"view","inputs":[{"type":"address"}],"outputs":[{"type":"uint256"}]},
 {"name":"allowance","type":"function","stateMutability":"view","inputs":[{"type":"address"},{"type":"address"}],"outputs":[{"type":"uint256"}]}
]`

// addressFromEnv reads a required 0x address from the environment.
func addressFromEnv(name string) (common.Address, error) {
	v := strings.TrimSpace(os.Getenv(name))
	if v == "" {
		return common.Address{}, errors.Errorf("%s is not set — the RFQ needs the FXRP and YT token addresses", name)
	}
	if !common.IsHexAddress(v) {
		return common.Address{}, errors.Errorf("%s is not a valid address: %q", name, v)
	}
	return common.HexToAddress(v), nil
}

// TokenAddresses returns the configured FXRP and YT addresses.
func TokenAddresses() (common.Address, common.Address, error) {
	fxrp, err := addressFromEnv("FXRP_ADDR")
	if err != nil {
		return common.Address{}, common.Address{}, err
	}
	yt, err := addressFromEnv("YT_ADDR")
	if err != nil {
		return common.Address{}, common.Address{}, err
	}
	return fxrp, yt, nil
}

func rfqContract(s *support.Support, addr common.Address) (*agamarfq.AgamaRfqInstructionSender, error) {
	c, err := agamarfq.NewAgamaRfqInstructionSender(addr, s.ChainClient)
	if err != nil {
		return nil, errors.Errorf("failed to bind RFQ contract: %s", err)
	}
	return c, nil
}

func transactor(s *support.Support) (*bind.TransactOpts, error) {
	opts, err := bind.NewKeyedTransactorWithChainID(s.Prv, s.ChainID)
	if err != nil {
		return nil, errors.Errorf("failed to create transactor: %s", err)
	}
	return opts, nil
}

// waitOK waits for a transaction and fails on a reverted receipt.
func waitOK(s *support.Support, tx *types.Transaction, what string) error {
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Minute)
	defer cancel()
	receipt, err := bind.WaitMined(ctx, s.ChainClient, tx)
	if err != nil {
		return errors.Errorf("%s not mined (tx %s): %s", what, tx.Hash().Hex(), err)
	}
	if receipt.Status != 1 {
		return errors.Errorf("%s reverted (tx %s)", what, tx.Hash().Hex())
	}
	return nil
}

// TokenApprove approves `spender` to move `amount` of `token` from the tooling key.
func TokenApprove(s *support.Support, token, spender common.Address, amount *big.Int) error {
	parsed, err := abi.JSON(strings.NewReader(erc20ABI))
	if err != nil {
		return errors.Errorf("bad ERC20 ABI: %s", err)
	}
	opts, err := transactor(s)
	if err != nil {
		return err
	}
	c := bind.NewBoundContract(token, parsed, s.ChainClient, s.ChainClient, s.ChainClient)
	tx, err := c.Transact(opts, "approve", spender, amount)
	if err != nil {
		return errors.Errorf("approve failed: %s", err)
	}
	return waitOK(s, tx, "approve")
}

// TokenAllowance reads an ERC20 allowance.
func TokenAllowance(s *support.Support, token, owner, spender common.Address) (*big.Int, error) {
	parsed, err := abi.JSON(strings.NewReader(erc20ABI))
	if err != nil {
		return nil, errors.Errorf("bad ERC20 ABI: %s", err)
	}
	c := bind.NewBoundContract(token, parsed, s.ChainClient, s.ChainClient, s.ChainClient)
	var out []interface{}
	if err := c.Call(&bind.CallOpts{}, &out, "allowance", owner, spender); err != nil {
		return nil, errors.Errorf("allowance call failed: %s", err)
	}
	return out[0].(*big.Int), nil
}

// SetTeeAddress points the RFQ at the registered TEE machine whose results it accepts.
func SetTeeAddress(s *support.Support, rfqAddress, teeAddress common.Address) error {
	c, err := rfqContract(s, rfqAddress)
	if err != nil {
		return err
	}
	opts, err := transactor(s)
	if err != nil {
		return err
	}
	tx, err := c.SetTeeAddress(opts, teeAddress)
	if err != nil {
		return errors.Errorf("setTeeAddress failed: %s", err)
	}
	return waitOK(s, tx, "setTeeAddress")
}

// OpenRfq escrows YT and opens an RFQ, returning its id.
func OpenRfq(s *support.Support, rfqAddress common.Address, ytAmount, minPrice *big.Int) (*big.Int, error) {
	c, err := rfqContract(s, rfqAddress)
	if err != nil {
		return nil, err
	}
	opts, err := transactor(s)
	if err != nil {
		return nil, err
	}
	tx, err := c.OpenRfq(opts, ytAmount, minPrice)
	if err != nil {
		return nil, errors.Errorf("openRfq failed: %s", err)
	}
	if err := waitOK(s, tx, "openRfq"); err != nil {
		return nil, err
	}
	next, err := c.NextId(&bind.CallOpts{})
	if err != nil {
		return nil, errors.Errorf("nextId call failed: %s", err)
	}
	return new(big.Int).Sub(next, big.NewInt(1)), nil
}

// RequestSettlement routes an RFQ/SETTLE instruction to the TEE and returns the instruction id.
func RequestSettlement(s *support.Support, rfqAddress common.Address, rfqId *big.Int) (common.Hash, error) {
	c, err := rfqContract(s, rfqAddress)
	if err != nil {
		return common.Hash{}, err
	}
	opts, err := transactor(s)
	if err != nil {
		return common.Hash{}, err
	}
	opts.Value = InstructionFee

	tx, err := c.RequestSettlement(opts, rfqId)
	if err != nil {
		return common.Hash{}, errors.Errorf("requestSettlement failed: %s", err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Minute)
	defer cancel()
	receipt, err := bind.WaitMined(ctx, s.ChainClient, tx)
	if err != nil {
		return common.Hash{}, errors.Errorf("requestSettlement not mined: %s", err)
	}
	if receipt.Status != 1 {
		return common.Hash{}, errors.New("requestSettlement reverted")
	}
	if len(receipt.Logs) == 0 {
		return common.Hash{}, errors.New("no logs in requestSettlement receipt")
	}
	instructionSent, err := s.TeeVerification.ParseTeeInstructionsSent(*receipt.Logs[0])
	if err != nil {
		return common.Hash{}, errors.Errorf("failed to parse TeeInstructionsSent event: %s", err)
	}
	return instructionSent.InstructionId, nil
}

// Settle relays the TEE-signed winning settlement on chain.
func Settle(
	s *support.Support,
	rfqAddress common.Address,
	resultData []byte,
	actionId common.Hash,
	submissionTag string,
	status uint8,
	signature []byte,
) (common.Hash, error) {
	c, err := rfqContract(s, rfqAddress)
	if err != nil {
		return common.Hash{}, err
	}
	opts, err := transactor(s)
	if err != nil {
		return common.Hash{}, err
	}
	tx, err := c.Settle(opts, resultData, actionId, submissionTag, status, signature)
	if err != nil {
		return common.Hash{}, errors.Errorf("settle failed: %s", err)
	}
	if err := waitOK(s, tx, "settle"); err != nil {
		return common.Hash{}, err
	}
	return tx.Hash(), nil
}
