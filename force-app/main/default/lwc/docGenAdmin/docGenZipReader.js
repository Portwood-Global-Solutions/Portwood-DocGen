/**
 * Pure JavaScript ZIP reader.
 *
 * Uses the browser's native DecompressionStream for deflate — zero external
 * dependencies. Reads classic ZIPs (store + deflate) produced by Google Docs,
 * Notion, macOS, Windows, etc. Returns [{ name, data: Uint8Array }, ...].
 */

async function inflateRaw(compressed) {
    const cs = new DecompressionStream('deflate-raw');
    const writer = cs.writable.getWriter();
    writer.write(compressed);
    writer.close();
    const reader = cs.readable.getReader();
    const chunks = [];
    let total = 0;
    for (;;) {
        const { done, value } = await reader.read();
        if (done) {
            break;
        }
        chunks.push(value);
        total += value.length;
    }
    const out = new Uint8Array(total);
    let offset = 0;
    for (const chunk of chunks) {
        out.set(chunk, offset);
        offset += chunk.length;
    }
    return out;
}

function u16(bytes, offset) {
    return bytes[offset] | (bytes[offset + 1] << 8);
}

function u32(bytes, offset) {
    return (bytes[offset] | (bytes[offset + 1] << 8) | (bytes[offset + 2] << 16) | (bytes[offset + 3] << 24)) >>> 0;
}

function findEocd(bytes) {
    const minSize = 22;
    const maxCommentLen = 65535;
    const scanFrom = Math.max(0, bytes.length - minSize - maxCommentLen);
    for (let i = bytes.length - minSize; i >= scanFrom; i--) {
        if (bytes[i] === 0x50 && bytes[i + 1] === 0x4b && bytes[i + 2] === 0x05 && bytes[i + 3] === 0x06) {
            return i;
        }
    }
    throw new Error('Not a valid ZIP file (end-of-central-directory marker not found).');
}

export async function readZip(input) {
    const bytes = input instanceof Uint8Array ? input : new Uint8Array(input);
    const eocd = findEocd(bytes);
    const totalEntries = u16(bytes, eocd + 10);
    const cdOffset = u32(bytes, eocd + 16);

    const entries = [];
    let cursor = cdOffset;
    for (let i = 0; i < totalEntries; i++) {
        if (u32(bytes, cursor) !== 0x02014b50) {
            throw new Error('Invalid central directory entry at offset ' + cursor);
        }
        const method = u16(bytes, cursor + 10);
        const compressedSize = u32(bytes, cursor + 20);
        const nameLen = u16(bytes, cursor + 28);
        const extraLen = u16(bytes, cursor + 30);
        const commentLen = u16(bytes, cursor + 32);
        const localHeaderOffset = u32(bytes, cursor + 42);
        const decoder = new TextDecoder('utf-8');
        const name = decoder.decode(bytes.subarray(cursor + 46, cursor + 46 + nameLen));
        cursor += 46 + nameLen + extraLen + commentLen;

        if (name.endsWith('/')) {
            continue;
        }

        if (u32(bytes, localHeaderOffset) !== 0x04034b50) {
            throw new Error('Invalid local header at offset ' + localHeaderOffset);
        }
        const lhNameLen = u16(bytes, localHeaderOffset + 26);
        const lhExtraLen = u16(bytes, localHeaderOffset + 28);
        const dataStart = localHeaderOffset + 30 + lhNameLen + lhExtraLen;
        const compressed = bytes.subarray(dataStart, dataStart + compressedSize);

        let data;
        if (method === 0) {
            data = new Uint8Array(compressed);
        } else if (method === 8) {
            // eslint-disable-next-line no-await-in-loop
            data = await inflateRaw(compressed);
        } else {
            throw new Error('Unsupported compression method ' + method + ' for entry ' + name);
        }

        entries.push({ name, data });
    }
    return entries;
}

export function bytesToBase64(bytes) {
    let binary = '';
    const chunkSize = 0x8000;
    for (let i = 0; i < bytes.length; i += chunkSize) {
        const slice = bytes.subarray(i, Math.min(i + chunkSize, bytes.length));
        binary += String.fromCharCode.apply(null, slice);
    }
    return btoa(binary);
}
