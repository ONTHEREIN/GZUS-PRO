// 登录密码的 RSA 加密：与 Flutter 端一致（SPKI 公钥 + PKCS#1 v1.5 填充），由后端 /auth/auto-login 解密。
// 浏览器 WebCrypto 不提供 PKCS#1 v1.5 加密，这里用 BigInt 自己实现，不引第三方库。
(function (root) {
  "use strict";

  function pemToBytes(pem) {
    const b64 = pem.replace(/-----[^-]+-----/g, "").replace(/\s+/g, "");
    const bin = atob(b64);
    const out = new Uint8Array(bin.length);
    for (let i = 0; i < bin.length; i += 1) out[i] = bin.charCodeAt(i);
    return out;
  }

  // 读一个 DER TLV，返回内容区间
  function readTlv(bytes, pos) {
    const tag = bytes[pos];
    let len = bytes[pos + 1];
    let start = pos + 2;
    if (len & 0x80) {
      const n = len & 0x7f;
      len = 0;
      for (let i = 0; i < n; i += 1) len = (len << 8) | bytes[start + i];
      start += n;
    }
    return { tag, start, end: start + len };
  }

  function bytesToBigInt(bytes) {
    let hex = "";
    for (const b of bytes) hex += b.toString(16).padStart(2, "0");
    return BigInt(`0x${hex || "0"}`);
  }

  function bigIntToBytes(value, length) {
    let hex = value.toString(16);
    if (hex.length % 2) hex = `0${hex}`;
    const raw = hex.match(/../g).map((h) => parseInt(h, 16));
    const out = new Uint8Array(length);
    out.set(raw, length - raw.length);
    return out;
  }

  function modPow(base, exp, mod) {
    let result = 1n;
    let b = base % mod;
    let e = exp;
    while (e > 0n) {
      if (e & 1n) result = (result * b) % mod;
      b = (b * b) % mod;
      e >>= 1n;
    }
    return result;
  }

  // SubjectPublicKeyInfo → (n, e)
  function parsePublicKey(pem) {
    const der = pemToBytes(pem);
    const spki = readTlv(der, 0);
    const algo = readTlv(der, spki.start);
    const bitString = readTlv(der, algo.end);
    if (bitString.tag !== 0x03) throw new Error("公钥格式不支持");
    const rsaKey = readTlv(der, bitString.start + 1); // 跳过 unused-bits 字节
    const nTlv = readTlv(der, rsaKey.start);
    const eTlv = readTlv(der, nTlv.end);
    let nBytes = der.slice(nTlv.start, nTlv.end);
    while (nBytes[0] === 0) nBytes = nBytes.slice(1);
    return { n: bytesToBigInt(nBytes), e: bytesToBigInt(der.slice(eTlv.start, eTlv.end)), k: nBytes.length };
  }

  function nonZeroRandom(length) {
    const out = new Uint8Array(length);
    let filled = 0;
    while (filled < length) {
      const chunk = new Uint8Array(length);
      root.crypto.getRandomValues(chunk);
      for (const b of chunk) {
        if (b !== 0 && filled < length) out[filled++] = b;
      }
    }
    return out;
  }

  function encryptPkcs1(plaintext, pem) {
    const { n, e, k } = parsePublicKey(pem);
    const message = new TextEncoder().encode(plaintext);
    if (message.length > k - 11) throw new Error("密码过长");
    const em = new Uint8Array(k);
    em[1] = 0x02;
    em.set(nonZeroRandom(k - message.length - 3), 2);
    em.set(message, k - message.length);
    const cipher = bigIntToBytes(modPow(bytesToBigInt(em), e, n), k);
    let bin = "";
    for (const b of cipher) bin += String.fromCharCode(b);
    return btoa(bin);
  }

  root.GzusRsa = { encryptPkcs1 };
})(typeof window !== "undefined" ? window : globalThis);
