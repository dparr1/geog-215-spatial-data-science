// Web Push (RFC 8030) with message encryption (RFC 8291, aes128gcm) and VAPID
// sign-in (RFC 8292), using only the Web Crypto API. No npm packages, so
// nothing to install or update.

const te = new TextEncoder();

export function b64uDecode(s: string): Uint8Array {
  s = s.replace(/-/g, "+").replace(/_/g, "/");
  while (s.length % 4) s += "=";
  const bin = atob(s);
  const out = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
  return out;
}

export function b64uEncode(bytes: Uint8Array): string {
  let s = "";
  for (const b of bytes) s += String.fromCharCode(b);
  return btoa(s).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

function concat(...parts: Uint8Array[]): Uint8Array {
  const out = new Uint8Array(parts.reduce((n, p) => n + p.length, 0));
  let i = 0;
  for (const p of parts) { out.set(p, i); i += p.length; }
  return out;
}

async function hkdf(salt: Uint8Array, ikm: Uint8Array, info: Uint8Array, bytes: number): Promise<Uint8Array> {
  const key = await crypto.subtle.importKey("raw", ikm, "HKDF", false, ["deriveBits"]);
  return new Uint8Array(await crypto.subtle.deriveBits({ name: "HKDF", hash: "SHA-256", salt, info }, key, bytes * 8));
}

export type Vapid = { publicKey: string; key: CryptoKey; subject: string };

// VAPID keys in the usual base64url form: the public key is the 65-byte
// uncompressed P-256 point, the private key the 32-byte scalar.
export async function loadVapid(publicKey: string, privateKey: string, subject: string): Promise<Vapid> {
  const pub = b64uDecode(publicKey);
  if (pub.length !== 65 || pub[0] !== 4) throw new Error("VAPID_PUBLIC_KEY isn't a P-256 public key.");
  const d = b64uDecode(privateKey);
  if (d.length !== 32) throw new Error("VAPID_PRIVATE_KEY isn't a P-256 private key.");
  const jwk = {
    kty: "EC", crv: "P-256", ext: true,
    x: b64uEncode(pub.slice(1, 33)), y: b64uEncode(pub.slice(33, 65)), d: b64uEncode(d),
  };
  const key = await crypto.subtle.importKey("jwk", jwk, { name: "ECDSA", namedCurve: "P-256" }, false, ["sign"]);
  return { publicKey, key, subject };
}

async function vapidHeader(endpoint: string, vapid: Vapid): Promise<string> {
  const aud = new URL(endpoint).origin;
  const head = b64uEncode(te.encode(JSON.stringify({ typ: "JWT", alg: "ES256" })));
  const claims = b64uEncode(te.encode(JSON.stringify({
    aud, exp: Math.floor(Date.now() / 1000) + 12 * 3600, sub: vapid.subject,
  })));
  const unsigned = head + "." + claims;
  // Web Crypto returns the raw r||s signature, which is what JWS ES256 uses.
  const sig = new Uint8Array(await crypto.subtle.sign({ name: "ECDSA", hash: "SHA-256" }, vapid.key, te.encode(unsigned)));
  return `vapid t=${unsigned}.${b64uEncode(sig)}, k=${vapid.publicKey}`;
}

// Encrypt one message for one subscription (RFC 8291). Returns the request body.
export async function encrypt(payload: Uint8Array, p256dh: string, authSecret: string): Promise<Uint8Array> {
  const uaPublic = b64uDecode(p256dh);
  const auth = b64uDecode(authSecret);
  const uaKey = await crypto.subtle.importKey("raw", uaPublic, { name: "ECDH", namedCurve: "P-256" }, false, []);
  const local = await crypto.subtle.generateKey({ name: "ECDH", namedCurve: "P-256" }, true, ["deriveBits"]) as CryptoKeyPair;
  const asPublic = new Uint8Array(await crypto.subtle.exportKey("raw", local.publicKey));
  const shared = new Uint8Array(await crypto.subtle.deriveBits({ name: "ECDH", public: uaKey }, local.privateKey, 256));

  const ikm = await hkdf(auth, shared, concat(te.encode("WebPush: info\0"), uaPublic, asPublic), 32);
  const salt = crypto.getRandomValues(new Uint8Array(16));
  const cek = await hkdf(salt, ikm, te.encode("Content-Encoding: aes128gcm\0"), 16);
  const nonce = await hkdf(salt, ikm, te.encode("Content-Encoding: nonce\0"), 12);

  const aes = await crypto.subtle.importKey("raw", cek, "AES-GCM", false, ["encrypt"]);
  const cipher = new Uint8Array(await crypto.subtle.encrypt(
    { name: "AES-GCM", iv: nonce }, aes, concat(payload, new Uint8Array([2])),   // 2 = last record
  ));
  const header = new Uint8Array(21);
  header.set(salt, 0);
  new DataView(header.buffer).setUint32(16, 4096);   // record size
  header[20] = asPublic.length;
  return concat(header, asPublic, cipher);
}

export type Subscription = { endpoint: string; p256dh: string; auth: string };
export type Result = "ok" | "gone" | "failed";

// Send one message. "gone" means the push service says the subscription no
// longer exists (notifications turned off, app deleted), so it can be removed.
export async function send(sub: Subscription, payload: string, vapid: Vapid, ttlSeconds = 86400): Promise<Result> {
  try {
    const body = await encrypt(te.encode(payload), sub.p256dh, sub.auth);
    const res = await fetch(sub.endpoint, {
      method: "POST",
      headers: {
        Authorization: await vapidHeader(sub.endpoint, vapid),
        "Content-Encoding": "aes128gcm",
        "Content-Type": "application/octet-stream",
        TTL: String(ttlSeconds),
        Urgency: "normal",
      },
      body,
    });
    await res.body?.cancel();
    if (res.status >= 200 && res.status < 300) return "ok";
    if (res.status === 404 || res.status === 410) return "gone";
    console.warn("push failed", new URL(sub.endpoint).host, res.status);
    return "failed";
  } catch (e) {
    console.warn("push error", e instanceof Error ? e.message : e);
    return "failed";
  }
}
