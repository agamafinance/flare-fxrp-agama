// Same-origin JSON-RPC proxy to Flare Coston2 (the public RPC does not send permissive
// CORS headers, so browser reads / receipt polling are proxied through here).
const UPSTREAM = 'https://coston2-api.flare.network/ext/C/rpc';

export async function POST(req: Request) {
  const body = await req.text();
  const r = await fetch(UPSTREAM, { method: 'POST', headers: { 'content-type': 'application/json' }, body });
  const text = await r.text();
  return new Response(text, { status: r.status, headers: { 'content-type': 'application/json' } });
}
