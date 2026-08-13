import { RPC_URL } from "@/lib/chain";

// Server-side JSON-RPC proxy: reads go through here so the browser never hits the
// public Flare RPC directly (no CORS, and the endpoint can be swapped in one place).
export async function POST(req: Request) {
  const body = await req.text();
  const upstream = await fetch(RPC_URL, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body,
  });
  const text = await upstream.text();
  return new Response(text, {
    status: upstream.status,
    headers: { "content-type": "application/json" },
  });
}
