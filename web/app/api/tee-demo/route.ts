// Confidential YT settlement over Flare Confidential Compute (a Flare Compute
// Extension). Two modes:
//  - demo (no body): our relayer opens the RFQ and both market makers are ours,
//    so anyone can watch a real on-chain confidential settlement in one click.
//  - user (body { rfqId }): the connected wallet already split FXRP -> YT and
//    opened its own RFQ; we only run the market-maker bids + enclave settlement
//    for it, so the premium lands in the user's wallet.
//
// The FCC flow, unlike a plain enclave endpoint: each market maker posts its
// SEALED quote straight to the extension proxy (POST /direct, RFQ/QUOTE) so the
// quote never touches the chain; settlement is triggered on chain by
// requestSettlement, which routes an RFQ/SETTLE instruction to a registered TEE
// machine (GCP Confidential Space, AMD SEV); the enclave runs best execution and
// the tee-node signs the winner; we relay that signed result to settle(), which
// verifies the signer is a machine the FlareTeeManager lists as active before
// moving any funds.
import {
  createPublicClient, createWalletClient, http, encodeAbiParameters, decodeAbiParameters,
  keccak256, stringToHex, toHex, parseEventLogs, type Hex,
} from 'viem';
import { privateKeyToAccount, sign, generatePrivateKey } from 'viem/accounts';
import { coston2 } from '@/lib/flare/config';

export const runtime = 'nodejs';
export const dynamic = 'force-dynamic';
export const maxDuration = 120; // FCC settlement is multi-step (on-chain request + async delivery)

const RPC_URL = coston2.rpcUrls.default.http[0];
const CHAIN_ID = 114n;
const ONE = 1_000_000n;
const YT_AMT = 100n * ONE;
const RESERVE = 2n * ONE;
const FEE = 1_000_000n; // instruction fee forwarded with requestSettlement

const rfqAbi = [
  { type: 'function', name: 'openRfq', stateMutability: 'nonpayable', inputs: [{ type: 'uint256' }, { type: 'uint256' }], outputs: [{ type: 'uint256' }] },
  { type: 'function', name: 'nextId', stateMutability: 'view', inputs: [], outputs: [{ type: 'uint256' }] },
  { type: 'function', name: 'rfqs', stateMutability: 'view', inputs: [{ type: 'uint256' }], outputs: [{ type: 'address' }, { type: 'uint256' }, { type: 'uint256' }, { type: 'uint256' }, { type: 'bool' }] },
  { type: 'function', name: 'requestSettlement', stateMutability: 'payable', inputs: [{ type: 'uint256' }], outputs: [{ type: 'bytes32' }] },
  {
    type: 'function', name: 'settle', stateMutability: 'nonpayable', outputs: [],
    inputs: [
      { name: '_resultData', type: 'bytes' }, { name: '_actionId', type: 'bytes32' },
      { name: '_submissionTag', type: 'string' }, { name: '_status', type: 'uint8' },
      { name: '_signature', type: 'bytes' },
    ],
  },
] as const;

const erc20Abi = [
  { type: 'function', name: 'mint', stateMutability: 'nonpayable', inputs: [{ type: 'address' }, { type: 'uint256' }], outputs: [] },
  { type: 'function', name: 'approve', stateMutability: 'nonpayable', inputs: [{ type: 'address' }, { type: 'uint256' }], outputs: [{ type: 'bool' }] },
  { type: 'function', name: 'balanceOf', stateMutability: 'view', inputs: [{ type: 'address' }], outputs: [{ type: 'uint256' }] },
  { type: 'function', name: 'allowance', stateMutability: 'view', inputs: [{ type: 'address' }, { type: 'address' }], outputs: [{ type: 'uint256' }] },
] as const;

const splitAbi = [
  { type: 'function', name: 'split', stateMutability: 'nonpayable', inputs: [{ type: 'uint256' }], outputs: [] },
] as const;
const YT = '0x1592f5cd44676f182162AC9DC09F9B12C68E0B4D' as Hex;
const SPLITTER = '0xcB633439CCa82035Dfb0553Caed2552818E3a29E' as Hex;

// The FlareTeeManager emits this when requestSettlement routes an instruction;
// its indexed instructionId is what the enclave answers under.
const instructionsSentEvent = {
  type: 'event', name: 'TeeInstructionsSent',
  inputs: [
    { indexed: true, name: 'extensionId', type: 'uint256' },
    { indexed: true, name: 'instructionId', type: 'bytes32' },
    { indexed: true, name: 'rewardEpochId', type: 'uint32' },
    { indexed: false, name: 'teeMachines', type: 'tuple[]', components: [{ name: 'teeId', type: 'address' }, { name: 'teeProxyId', type: 'address' }, { name: 'url', type: 'string' }] },
    { indexed: false, name: 'opType', type: 'bytes32' },
    { indexed: false, name: 'opCommand', type: 'bytes32' },
    { indexed: false, name: 'message', type: 'bytes' },
    { indexed: false, name: 'cosigners', type: 'address[]' },
    { indexed: false, name: 'cosignersThreshold', type: 'uint64' },
    { indexed: false, name: 'claimBackAddress', type: 'address' },
    { indexed: false, name: 'fee', type: 'uint256' },
  ],
} as const;

function quoteDigest(rfq: Hex, rfqId: bigint, mm: Hex, price: bigint, deadline: bigint): Hex {
  return keccak256(encodeAbiParameters(
    [{ type: 'string' }, { type: 'uint256' }, { type: 'address' }, { type: 'uint256' }, { type: 'address' }, { type: 'uint256' }, { type: 'uint256' }, { type: 'uint256' }],
    ['AnchorQuote', CHAIN_ID, rfq, rfqId, mm, YT_AMT, price, deadline],
  ));
}

async function signedQuoteBody(privateKey: Hex, rfq: Hex, rfqId: bigint, claimedMm: Hex, price: bigint, deadline: bigint) {
  const sig = await sign({ hash: quoteDigest(rfq, rfqId, claimedMm, price, deadline), privateKey, to: 'hex' });
  return { rfq: rfq.toLowerCase(), chainId: Number(CHAIN_ID), rfqId: Number(rfqId), mm: claimedMm.toLowerCase(), price: Number(price), deadline: Number(deadline), sig };
}

// One RFQ/QUOTE or RFQ/SETTLE direct action, in the shape the proxy accepts.
function directAction(opCommand: 'QUOTE' | 'SETTLE', message: Hex) {
  return { opType: stringToHex('RFQ', { size: 32 }), opCommand: stringToHex(opCommand, { size: 32 }), message };
}

async function postDirect(enclave: string, opCommand: 'QUOTE' | 'SETTLE', message: Hex) {
  const r = await fetch(enclave + '/direct', {
    method: 'POST', headers: { 'content-type': 'application/json' },
    body: JSON.stringify(directAction(opCommand, message)),
  });
  const j = await r.json();
  return j?.data?.id as Hex;
}

// Poll the proxy for a signed action result. Direct actions carry the "submit"
// tag; an on-chain instruction is answered under "threshold".
async function pollResult(enclave: string, id: Hex, tag: 'submit' | 'threshold', tries = 25) {
  for (let i = 0; i < tries; i++) {
    const r = await fetch(`${enclave}/action/result/${id}?submissionTag=${tag}`);
    if (r.ok) {
      const body = await r.json();
      if (body?.result) return body as { result: { id: Hex; submissionTag: string; status: number; log: string; data: Hex }; signature: Hex };
    }
    await new Promise((res) => setTimeout(res, 2000));
  }
  return null;
}

export async function POST(req: Request) {
  const env = process.env;
  if (!env.DEMO_PRIVATE_KEY || !env.MM1_KEY || !env.MM2_KEY) {
    return Response.json({ error: 'RFQ settlement not configured (missing enclave/relayer keys)' }, { status: 503 });
  }
  let body: { rfqId?: number } = {};
  try { body = await req.json(); } catch { /* no body = demo mode */ }
  const userRfqId = body?.rfqId;

  // The FCC deployment is pinned here, not read from the environment, so a stale
  // ENCLAVE_URL/RFQ_ADDR left over from the earlier Intel-TDX stack cannot send
  // the demo to the wrong enclave or contract. Only the signing keys come from env.
  const ENCLAVE = 'http://136.113.147.228:6674'; // extension proxy (:6674), stable support-VM IP
  const RFQ = '0x40d282d699698193eE7f0379039E1aa0ec7016b6' as Hex; // AgamaRfqInstructionSender, ext 66302
  const FXRP = '0xb23b0daDa02c86D2A7E76d2060c34Fff14D1E3A6' as Hex;

  try {
    const pub = createPublicClient({ chain: coston2, transport: http(RPC_URL) });
    const demo = privateKeyToAccount(env.DEMO_PRIVATE_KEY as Hex);
    const relayer = createWalletClient({ account: demo, chain: coston2, transport: http(RPC_URL) });
    const mm1 = privateKeyToAccount(env.MM1_KEY as Hex);
    const mm2 = privateKeyToAccount(env.MM2_KEY as Hex);
    const send = async (tx: Promise<Hex>) => { const h = await tx; await pub.waitForTransactionReceipt({ hash: h }); return h; };

    // 1. live enclave identity (the extension proxy's /info: real AMD SEV, code hash)
    const info = await (await fetch(ENCLAVE + '/info')).json();
    const md = info?.machineData ?? {};
    const platRaw: string = md.platform || '';
    const platform = platRaw.startsWith('0x') ? Buffer.from(platRaw.slice(2), 'hex').toString().replace(/\0+$/, '') : platRaw;
    const teeId = ('0x' + keccak256(('0x' + (info.teeInfo.publicKey.x.slice(2)) + (info.teeInfo.publicKey.y.slice(2))) as Hex).slice(-40)) as Hex;

    // 2. the RFQ to settle: the user's already-open one, or our demo seller opens one
    let rfqId: bigint; let seller: Hex; let openTx: Hex | null = null;
    if (userRfqId != null) {
      rfqId = BigInt(userRfqId);
      const in0 = (await pub.readContract({ address: RFQ, abi: rfqAbi, functionName: 'rfqs', args: [rfqId] })) as readonly [Hex, bigint, bigint, bigint, boolean];
      seller = in0[0];
      if (!in0[4]) return Response.json({ error: 'that RFQ is not open (or already settled)' }, { status: 400 });
    } else {
      // Demo seller: each settlement hands its escrowed YT to the winner, so top
      // the YT up first. YT has no open mint — it is the yield half of split FXRP —
      // so mint demo FXRP, split it, and approve the RFQ to escrow the YT.
      const ytBal = (await pub.readContract({ address: YT, abi: erc20Abi, functionName: 'balanceOf', args: [demo.address] })) as bigint;
      if (ytBal < YT_AMT) {
        const short = YT_AMT - ytBal;
        await send(relayer.writeContract({ address: FXRP, abi: erc20Abi, functionName: 'mint', args: [demo.address, short * 2n] }));
        await send(relayer.writeContract({ address: FXRP, abi: erc20Abi, functionName: 'approve', args: [SPLITTER, short] }));
        await send(relayer.writeContract({ address: SPLITTER, abi: splitAbi, functionName: 'split', args: [short] }));
      }
      await send(relayer.writeContract({ address: YT, abi: erc20Abi, functionName: 'approve', args: [RFQ, YT_AMT] }));
      openTx = await send(relayer.writeContract({ address: RFQ, abi: rfqAbi, functionName: 'openRfq', args: [YT_AMT, RESERVE] }));
      rfqId = ((await pub.readContract({ address: RFQ, abi: rfqAbi, functionName: 'nextId' })) as bigint) - 1n;
      seller = demo.address;
    }
    const deadline = BigInt(Math.floor(Date.now() / 1000) + 3600);

    // 3. the market makers must be able to pay the premium at settlement: FXRP to
    //    pay it and an approval for the contract to pull it. The relayer mints the
    //    FXRP (its gas, no MM tx). The approval is the MM's own tx, so the relayer
    //    first tops up the MM's gas if needed; a large one-time allowance means
    //    later runs skip the MM tx entirely.
    const MAX = (1n << 256n) - 1n;
    const GAS_MIN = 10n ** 17n; // 0.1 C2FLR
    for (const mm of [mm1, mm2]) {
      const mmWallet = createWalletClient({ account: mm, chain: coston2, transport: http(RPC_URL) });
      const bal = (await pub.readContract({ address: FXRP, abi: erc20Abi, functionName: 'balanceOf', args: [mm.address] })) as bigint;
      if (bal < 6n * ONE) await send(relayer.writeContract({ address: FXRP, abi: erc20Abi, functionName: 'mint', args: [mm.address, 24n * ONE] }));
      const alw = (await pub.readContract({ address: FXRP, abi: erc20Abi, functionName: 'allowance', args: [mm.address, RFQ] })) as bigint;
      if (alw < 6n * ONE) {
        const gas = await pub.getBalance({ address: mm.address });
        if (gas < GAS_MIN) await send(relayer.sendTransaction({ to: mm.address, value: 5n * GAS_MIN }));
        await send(mmWallet.writeContract({ address: FXRP, abi: erc20Abi, functionName: 'approve', args: [RFQ, MAX] }));
      }
    }

    // 4. guardrail: a quote forged for another MM is rejected inside the enclave
    const forgedId = await postDirect(ENCLAVE, 'QUOTE', toHex(Buffer.from(JSON.stringify(await signedQuoteBody(generatePrivateKey(), RFQ, rfqId, mm1.address, 5n * ONE, deadline)))));
    const forgedRes = await pollResult(ENCLAVE, forgedId, 'submit');
    const forgedRejected = !!forgedRes && forgedRes.result.status === 0;

    // 5. two authentic SEALED bids straight to the enclave (randomize who bids high)
    const highFirst = Math.random() < 0.5;
    const pA = highFirst ? 6n * ONE : 4n * ONE;
    const pB = highFirst ? 4n * ONE : 6n * ONE;
    for (const [key, mm, price] of [[env.MM1_KEY, mm1, pA], [env.MM2_KEY, mm2, pB]] as const) {
      const qid = await postDirect(ENCLAVE, 'QUOTE', toHex(Buffer.from(JSON.stringify(await signedQuoteBody(key as Hex, RFQ, rfqId, mm.address, price, deadline)))));
      const qr = await pollResult(ENCLAVE, qid, 'submit');
      if (!qr || qr.result.status !== 1) return Response.json({ error: 'enclave rejected a quote: ' + (qr?.result.log || 'no result') }, { status: 502 });
    }

    // 6+7. trigger settlement ON CHAIN and wait for the enclave-signed result.
    // requestSettlement routes to a random active machine and the proxy delivers
    // the instruction to it; a transient proxy->node timeout yields a status-0
    // result for that instruction. Signing does not consume the quotes and the
    // RFQ stays open, so re-requesting is safe — retry a couple of times before
    // giving up, so one slow delivery does not fail the whole demo.
    let settleRes: Awaited<ReturnType<typeof pollResult>> = null;
    let lastLog = 'no result';
    for (let attempt = 0; attempt < 2 && (!settleRes || settleRes.result.status !== 1); attempt++) {
      const reqHash = await relayer.writeContract({ address: RFQ, abi: rfqAbi, functionName: 'requestSettlement', args: [rfqId], value: FEE });
      const reqReceipt = await pub.waitForTransactionReceipt({ hash: reqHash });
      const sent = parseEventLogs({ abi: [instructionsSentEvent], logs: reqReceipt.logs })[0];
      if (!sent) { lastLog = 'no TeeInstructionsSent event'; continue; }
      const instructionId = (sent.args as { instructionId: Hex }).instructionId;
      settleRes = await pollResult(ENCLAVE, instructionId, 'threshold');
      if (settleRes && settleRes.result.status !== 1) lastLog = settleRes.result.log || lastLog;
    }
    if (!settleRes || settleRes.result.status !== 1) return Response.json({ error: 'enclave did not settle: ' + lastLog }, { status: 502 });
    const [, , , winner, , price] = decodeAbiParameters(
      [{ type: 'address' }, { type: 'uint256' }, { type: 'address' }, { type: 'address' }, { type: 'uint256' }, { type: 'uint256' }, { type: 'uint256' }],
      settleRes.result.data,
    ) as [Hex, bigint, Hex, Hex, bigint, bigint, bigint];
    const won1 = winner.toLowerCase() === mm1.address.toLowerCase();

    // 8. relay the signed result; settle() verifies the signer is an active machine
    const settleTx = await send(relayer.writeContract({
      address: RFQ, abi: rfqAbi, functionName: 'settle',
      args: [settleRes.result.data, settleRes.result.id, settleRes.result.submissionTag, settleRes.result.status, settleRes.signature],
    }));

    return Response.json({
      mode: userRfqId != null ? 'user' : 'demo',
      seller,
      enclave: { address: teeId, issuer: 'Flare Confidential Compute', hwmodel: platform || 'GCP_AMD_SEV', dbgstat: md.dbgstat || 'disabled-since-boot', imageDigest: md.codeHash },
      onchainTrusted: true,
      extensionId: md.extensionId ? Number(BigInt(md.extensionId)) : undefined,
      rfqId: Number(rfqId),
      openTx,
      reserve: 2,
      forgedRejected,
      bids: [
        { mm: mm1.address, price: Number(pA / ONE), won: won1 },
        { mm: mm2.address, price: Number(pB / ONE), won: !won1 },
      ],
      winner,
      price: Number(price / ONE),
      settleTx,
      explorer: 'https://coston2-explorer.flare.network',
    });
  } catch (e) {
    const err = e as { shortMessage?: string; message?: string };
    return Response.json({ error: err?.shortMessage || err?.message || 'settlement failed' }, { status: 500 });
  }
}
