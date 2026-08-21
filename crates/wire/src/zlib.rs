//! Wire compression (firebird.conf `WireCompression`): once both sides
//! set `pflag_compress` in the protocol negotiation, everything after
//! the accept packet is ONE zlib stream each way (remote.cpp
//! `REMOTE_deflate` / `REMOTE_inflate`; compression below the wire
//! encryption - the peer deflates, then encrypts). The peer flushes with
//! `Z_SYNC_FLUSH` per packet, so every packet it sends is whole deflate
//! blocks ending in an empty stored block.
//!
//! This side SENDS stored (uncompressed) blocks - a legal zlib stream
//! any inflater reads, with no compressor to write - and INFLATES what
//! it receives: RFC 1950 header, RFC 1951 stored / fixed-Huffman /
//! dynamic-Huffman blocks, decoded block by block from the bytes so far.
//! A block cut short by the end of the input is retried from its start
//! once more input arrives (the peer's sync flush guarantees whole
//! blocks per packet, so a retry is rare and bounded).

/// The inflater's input so far and what it has produced.
#[derive(Default)]
pub struct Inflater {
    input: Vec<u8>,
    /// bit position of the next block in `input`
    pos: usize,
    header_done: bool,
    /// the last 32 KB of output, for back-references
    window: Vec<u8>,
    pub out: std::collections::VecDeque<u8>,
}

struct Bits<'a> {
    data: &'a [u8],
    pos: usize,
}

impl<'a> Bits<'a> {
    fn bit(&mut self) -> Option<u32> {
        let byte = *self.data.get(self.pos >> 3)?;
        let b = (byte >> (self.pos & 7)) & 1;
        self.pos += 1;
        Some(u32::from(b))
    }
    fn bits(&mut self, n: u32) -> Option<u32> {
        let mut v = 0u32;
        for i in 0..n {
            v |= self.bit()? << i;
        }
        Some(v)
    }
    fn align(&mut self) {
        self.pos = (self.pos + 7) & !7;
    }
}

/// A canonical Huffman decoder: code lengths -> (counts per length,
/// symbols in code order), decoded bit by bit (puff.c's scheme).
struct Huffman {
    counts: [u16; 16],
    symbols: Vec<u16>,
}

impl Huffman {
    fn new(lengths: &[u8]) -> Huffman {
        let mut counts = [0u16; 16];
        for &l in lengths {
            counts[l as usize] += 1;
        }
        counts[0] = 0;
        let mut offs = [0u16; 16];
        for i in 1..16 {
            offs[i] = offs[i - 1] + counts[i - 1];
        }
        let mut symbols = vec![0u16; lengths.len()];
        for (sym, &l) in lengths.iter().enumerate() {
            if l != 0 {
                symbols[offs[l as usize] as usize] = sym as u16;
                offs[l as usize] += 1;
            }
        }
        Huffman { counts, symbols }
    }
    fn decode(&self, b: &mut Bits) -> Option<u16> {
        let mut code: i32 = 0;
        let mut first: i32 = 0;
        let mut index: i32 = 0;
        for len in 1..16 {
            code |= b.bit()? as i32;
            let count = i32::from(self.counts[len]);
            if code - count < first {
                return self.symbols.get((index + (code - first)) as usize).copied();
            }
            index += count;
            first += count;
            first <<= 1;
            code <<= 1;
        }
        None
    }
}

const LEN_BASE: [u16; 29] = [3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31, 35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258];
const LEN_EXTRA: [u8; 29] = [0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0];
const DIST_BASE: [u16; 30] = [1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193, 257, 385, 513, 769, 1025, 1537, 2049, 3073, 4097, 6145, 8193, 12289, 16385, 24577];
const DIST_EXTRA: [u8; 30] = [0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13];

impl Inflater {
    pub fn new() -> Inflater {
        Inflater::default()
    }

    /// Feed compressed bytes; decode every whole block they complete.
    pub fn feed(&mut self, bytes: &[u8]) -> Result<(), String> {
        self.input.extend_from_slice(bytes);
        if !self.header_done {
            if self.input.len() < 2 {
                return Ok(());
            }
            let cmf = self.input[0];
            let flg = self.input[1];
            if cmf & 0x0f != 8 || (u16::from(cmf) << 8 | u16::from(flg)) % 31 != 0 || flg & 0x20 != 0 {
                return Err("not a zlib stream".into());
            }
            self.header_done = true;
            self.pos = 16;
        }
        loop {
            let start = self.pos;
            let mut produced: Vec<u8> = Vec::new();
            let mut b = Bits { data: &self.input, pos: start };
            match Self::block(&mut b, &self.window, &mut produced) {
                Some(_final) => {
                    self.pos = b.pos;
                    for &x in &produced {
                        self.out.push_back(x);
                        self.window.push(x);
                    }
                    if self.window.len() > 65536 {
                        let cut = self.window.len() - 32768;
                        self.window.drain(..cut);
                    }
                }
                None => {
                    // cut short: keep the input, retry from the block start
                    self.pos = start;
                    break;
                }
            }
        }
        // drop consumed whole bytes
        let whole = self.pos / 8;
        if whole > 0 {
            self.input.drain(..whole);
            self.pos -= whole * 8;
        }
        Ok(())
    }

    /// One deflate block; None when the input ends before it does.
    /// Returns its BFINAL flag.
    fn block(b: &mut Bits, window: &[u8], out: &mut Vec<u8>) -> Option<bool> {
        let bfinal = b.bit()? == 1;
        let btype = b.bits(2)?;
        match btype {
            0 => {
                b.align();
                let len = b.bits(16)? as usize;
                let nlen = b.bits(16)? as usize;
                if len != (!nlen & 0xffff) {
                    return None;
                }
                let at = b.pos / 8;
                if at + len > b.data.len() {
                    return None;
                }
                out.extend_from_slice(&b.data[at..at + len]);
                b.pos += len * 8;
            }
            1 => {
                let mut lengths = [0u8; 288];
                for (i, l) in lengths.iter_mut().enumerate() {
                    *l = match i {
                        0..=143 => 8,
                        144..=255 => 9,
                        256..=279 => 7,
                        _ => 8,
                    };
                }
                let lit = Huffman::new(&lengths);
                let dist = Huffman::new(&[5u8; 30]);
                Self::codes(b, &lit, &dist, window, out)?;
            }
            2 => {
                let hlit = b.bits(5)? as usize + 257;
                let hdist = b.bits(5)? as usize + 1;
                let hclen = b.bits(4)? as usize + 4;
                const ORDER: [usize; 19] = [16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15];
                let mut cl = [0u8; 19];
                for &o in ORDER.iter().take(hclen) {
                    cl[o] = b.bits(3)? as u8;
                }
                let clh = Huffman::new(&cl);
                let mut lengths = vec![0u8; hlit + hdist];
                let mut i = 0;
                while i < hlit + hdist {
                    let sym = clh.decode(b)?;
                    match sym {
                        0..=15 => {
                            lengths[i] = sym as u8;
                            i += 1;
                        }
                        16 => {
                            if i == 0 {
                                return None;
                            }
                            let prev = lengths[i - 1];
                            let n = 3 + b.bits(2)? as usize;
                            for _ in 0..n {
                                if i >= lengths.len() {
                                    return None;
                                }
                                lengths[i] = prev;
                                i += 1;
                            }
                        }
                        17 => {
                            let n = 3 + b.bits(3)? as usize;
                            i += n;
                        }
                        _ => {
                            let n = 11 + b.bits(7)? as usize;
                            i += n;
                        }
                    }
                }
                if i > hlit + hdist {
                    return None;
                }
                let lit = Huffman::new(&lengths[..hlit]);
                let dist = Huffman::new(&lengths[hlit..]);
                Self::codes(b, &lit, &dist, window, out)?;
            }
            _ => return None,
        }
        Some(bfinal)
    }

    fn codes(b: &mut Bits, lit: &Huffman, dist: &Huffman, window: &[u8], out: &mut Vec<u8>) -> Option<()> {
        loop {
            let sym = lit.decode(b)? as usize;
            if sym < 256 {
                out.push(sym as u8);
            } else if sym == 256 {
                return Some(());
            } else {
                let li = sym - 257;
                if li >= 29 {
                    return None;
                }
                let len = LEN_BASE[li] as usize + b.bits(u32::from(LEN_EXTRA[li]))? as usize;
                let di = dist.decode(b)? as usize;
                if di >= 30 {
                    return None;
                }
                let d = DIST_BASE[di] as usize + b.bits(u32::from(DIST_EXTRA[di]))? as usize;
                // the reference reaches into this block's output, then the window
                for _ in 0..len {
                    let byte = if d <= out.len() {
                        out[out.len() - d]
                    } else {
                        let back = d - out.len();
                        if back > window.len() {
                            return None;
                        }
                        window[window.len() - back]
                    };
                    out.push(byte);
                }
            }
        }
    }
}

/// The zlib header this side sends once, then `stored_blocks` per send.
pub const ZLIB_HEADER: [u8; 2] = [0x78, 0x01];

/// `data` as stored (uncompressed) deflate blocks, none final - what a
/// `Z_SYNC_FLUSH` of an incompressible buffer looks like; the peer's
/// inflate hands the bytes on as they come.
pub fn stored_blocks(data: &[u8]) -> Vec<u8> {
    let mut out = Vec::with_capacity(data.len() + 5 * (data.len() / 65535 + 1));
    for chunk in data.chunks(65535) {
        out.push(0); // BFINAL 0, BTYPE 00
        let len = chunk.len() as u16;
        out.extend_from_slice(&len.to_le_bytes());
        out.extend_from_slice(&(!len).to_le_bytes());
        out.extend_from_slice(chunk);
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn inflates_stored_and_fixed_blocks() {
        // our own stored framing round-trips
        let mut inf = Inflater::new();
        let mut stream = ZLIB_HEADER.to_vec();
        stream.extend(stored_blocks(b"hello, stored world"));
        inf.feed(&stream).unwrap();
        let got: Vec<u8> = inf.out.drain(..).collect();
        assert_eq!(got, b"hello, stored world");
        // a fixed-Huffman block (python zlib.compress(b"aaaa"*4, 9) with sync flush)
        // 78 da 4b 4c 84 03 00 -> "aaaaaaaaaaaaaaaa" ... here the classic
        // "abc" compressed: 78 9c 4b 4c 4a 06 00 02 4d 01 27
        let abc = [0x78u8, 0x9c, 0x4b, 0x4c, 0x4a, 0x06, 0x00, 0x02, 0x4d, 0x01, 0x27];
        let mut inf = Inflater::new();
        inf.feed(&abc[..6]).unwrap(); // cut mid-block: nothing yet
        assert!(inf.out.is_empty());
        inf.feed(&abc[6..]).unwrap();
        let got: Vec<u8> = inf.out.drain(..).collect();
        assert_eq!(got, b"abc");
    }
}
