// Real confidential YT settlement: seller opens an on-chain RFQ, two market makers submit
// SEALED bids to the live Flare Confidential Compute enclave (GCP Confidential Space, Intel TDX),
// the enclave picks best execution and signs only the winner, and we relay that enclave-signed
// settlement on chain where ConfidentialYtRfq verifies the signature against its attested key and
// settles atomically. Losing / forged quotes never touch the chain.
import { createPublicClient, createWalletClient, http, encodeAbiParameters, keccak256, type Hex } from 'viem';
import { privateKeyToAccount, sign, generatePrivateKey } from 'viem/accounts';
import { coston2 } from '@/lib/flare/config';

export const runtime = 'nodejs';
export const dynamic = 'force-dynamic';
export const maxDuration = 60;

const RPC_URL = coston2.rpcUrls.default.http[0];
const CHAIN_ID = 114n;
const ONE = 1_000_000n;
const YT_AMT = 100n * ONE;
const RESERVE = 2n * ONE;

const rfqAbi = [
  { type: 'function', name: 'openRfq', stateMutability: 'nonpayable', inputs: [{ type: 'uint256' }, { type: 'uint256' }], outputs: [{ type: 'uint256' }] },
  { type: 'function', name: 'nextId', stateMutability: 'view', inputs: [], outputs: [{ type: 'uint256' }] },
  { type: 'function', name: 'enclaveSigner', stateMutability: 'view', inputs: [], outputs: [{ type: 'address' }] },
  {
    type: 'function', name: 'settle', stateMutability: 'nonpayable', outputs: [],
    inputs: [
      { name: 's', type: 'tuple', components: [{ type: 'uint256' }, { type: 'address' }, { type: 'address' }, { type: 'uint256' }, { type: 'uint256' }, { type: 'uint256' }] },
      { type: 'uint8' }, { type: 'bytes32' }, { type: 'bytes32' },
    ],
  },
] as const;

function quoteDigest(rfq: Hex, rfqId: bigint, mm: Hex, price: bigint, deadline: bigint): Hex {
  return keccak256(encodeAbiParameters(
    [{ type: 'string' }, { type: 'uint256' }, { type: 'address' }, { type: 'uint256' }, { type: 'address' }, { type: 'uint256' }, { type: 'uint256' }, { type: 'uint256' }],
    ['AnchorQuote', CHAIN_ID, rfq, rfqId, mm, YT_AMT, price, deadline],
  ));
}

async function signedQuote(privateKey: Hex, rfq: Hex, rfqId: bigint, claimedMm: Hex, price: bigint, deadline: bigint) {
  const sig = await sign({ hash: quoteDigest(rfq, rfqId, claimedMm, price, deadline), privateKey, to: 'hex' });
  return { mm: claimedMm, price: Number(price), deadline: Number(deadline), sig };
}

export async function POST() {
  const env = process.env;
  if (!env.DEMO_PRIVATE_KEY || !env.MM1_KEY || !env.MM2_KEY) {
    return Response.json({ error: 'RFQ settlement not configured (missing enclave/relayer keys)' }, { status: 503 });
  }
  const ENCLAVE = env.ENCLAVE_URL || 'http://34.59.74.87:8080';
  const RFQ = (env.RFQ_ADDR || '0x73F18087dd45d180e75cADcD383479624326E336') as Hex;
  const post = (rfqId: bigint, quotes: unknown[]) =>
    fetch(ENCLAVE + '/settle', { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify({ rfq: RFQ, chainId: Number(CHAIN_ID), rfqId: Number(rfqId), quotes }) });

  try {
    const pub = createPublicClient({ chain: coston2, transport: http(RPC_URL) });
    const demo = privateKeyToAccount(env.DEMO_PRIVATE_KEY as Hex);
    const wallet = createWalletClient({ account: demo, chain: coston2, transport: http(RPC_URL) });
    const mm1 = privateKeyToAccount(env.MM1_KEY as Hex);
    const mm2 = privateKeyToAccount(env.MM2_KEY as Hex);

    // 1. live enclave identity + TDX attestation
    const pubkey = (await (await fetch(ENCLAVE + '/pubkey')).json()).address as string;
    let tok = (await (await fetch(ENCLAVE + '/attestation')).text()).trim().replace(/^"|"$/g, '');
    try { tok = JSON.parse(tok).token ?? tok; } catch { /* raw jwt */ }
    const claims = JSON.parse(Buffer.from(tok.split('.')[1], 'base64url').toString());
    const onchainSigner = (await pub.readContract({ address: RFQ, abi: rfqAbi, functionName: 'enclaveSigner' })) as string;
    const onchainTrusted = onchainSigner.toLowerCase() === pubkey.toLowerCase();

    // 2. seller opens the RFQ (YT + approval are pre-provisioned, so this is a single tx)
    const openTx = await wallet.writeContract({ address: RFQ, abi: rfqAbi, functionName: 'openRfq', args: [YT_AMT, RESERVE] });
    await pub.waitForTransactionReceipt({ hash: openTx });
    const rfqId = ((await pub.readContract({ address: RFQ, abi: rfqAbi, functionName: 'nextId' })) as bigint) - 1n;
    const deadline = BigInt(Math.floor(Date.now() / 1000) + 3600);

    // 3. guardrail: a quote forged for another MM is rejected off-chain by the enclave
    const forged = await signedQuote(generatePrivateKey(), RFQ, rfqId, mm1.address, 5n * ONE, deadline);
    const forgedRejected = (await post(rfqId, [forged])).status === 400;

    // 4. two authentic SEALED bids (randomize which MM bids higher)
    const highFirst = Math.random() < 0.5;
    const pA = highFirst ? 6n * ONE : 4n * ONE;
    const pB = highFirst ? 4n * ONE : 6n * ONE;
    const q1 = await signedQuote(env.MM1_KEY as Hex, RFQ, rfqId, mm1.address, pA, deadline);
    const q2 = await signedQuote(env.MM2_KEY as Hex, RFQ, rfqId, mm2.address, pB, deadline);
    const rC = await post(rfqId, [q1, q2]);
    if (!rC.ok) return Response.json({ error: 'enclave: ' + (await rC.text()).slice(0, 200) }, { status: 502 });
    const s = await rC.json();
    const winner = s.winner as string;
    const won1 = winner.toLowerCase() === mm1.address.toLowerCase();

    // 5. relay the enclave-signed settlement; the contract verifies and settles atomically
    const settleTx = await wallet.writeContract({
      address: RFQ, abi: rfqAbi, functionName: 'settle',
      args: [[rfqId, demo.address, winner as Hex, BigInt(s.ytAmount), BigInt(s.price), BigInt(s.deadline)], Number(s.v), s.r as Hex, s.s as Hex],
    });
    await pub.waitForTransactionReceipt({ hash: settleTx });

    return Response.json({
      seller: demo.address,
      enclave: { address: pubkey, issuer: claims.iss, hwmodel: claims.hwmodel, dbgstat: claims.dbgstat, imageDigest: claims.submods?.container?.image_digest },
      onchainTrusted,
      rfqId: Number(rfqId),
      openTx,
      reserve: 2,
      forgedRejected,
      bids: [
        { mm: mm1.address, price: Number(pA / ONE), won: won1 },
        { mm: mm2.address, price: Number(pB / ONE), won: !won1 },
      ],
      winner,
      price: Number(BigInt(s.price) / ONE),
      settleTx,
      explorer: 'https://coston2-explorer.flare.network',
    });
  } catch (e) {
    const err = e as { shortMessage?: string; message?: string };
    return Response.json({ error: err?.shortMessage || err?.message || 'settlement failed' }, { status: 500 });
  }
}
