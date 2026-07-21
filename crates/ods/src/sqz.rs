//! Record run-length compression, converted from `src/jrd/sqz.cpp`.
//!
//! Every record version on a data page is stored RLE-compressed. The
//! scheme is a stream of signed control bytes:
//!
//! - `n > 0`: the next `n` bytes are literal data.
//! - `n in -128..=-3`: the next ONE byte repeats `-n` times.
//! - `n == -1` (Firebird 4+): a little-endian `u16` length follows,
//!   then the byte to repeat - long runs without chaining -128s.
//! - `n == -2` (Firebird 4+): same with a `u32` length.
//!
//! The decompressor accepts all forms (like `Compressor::unpack`); the
//! compressor here emits the classic forms plus `-1` for long runs -
//! enough for byte-exact round trips and for compressing test data the
//! C++ engine would accept.

/// Decompress `input` into a Vec. Returns None on a malformed stream
/// (truncated run), mirroring unpack's "decompression error" path.
pub fn unpack(input: &[u8]) -> Option<Vec<u8>> {
    let mut out = Vec::with_capacity(input.len() * 2);
    let mut i = 0usize;
    while i < input.len() {
        let control = input[i] as i8;
        i += 1;
        if control >= 0 {
            let n = control as usize;
            if i + n > input.len() {
                return None;
            }
            out.extend_from_slice(&input[i..i + n]);
            i += n;
        } else {
            let run: usize = match control {
                -1 => {
                    if i + 2 > input.len() {
                        return None;
                    }
                    let n = u16::from_le_bytes([input[i], input[i + 1]]) as usize;
                    i += 2;
                    n
                }
                -2 => {
                    if i + 4 > input.len() {
                        return None;
                    }
                    let n = u32::from_le_bytes([input[i], input[i + 1], input[i + 2], input[i + 3]])
                        as usize;
                    i += 4;
                    n
                }
                _ => (-(control as i32)) as usize,
            };
            if i >= input.len() {
                return None;
            }
            let b = input[i];
            i += 1;
            out.resize(out.len() + run, b);
        }
    }
    Some(out)
}

/// Compress `input`. Runs of 3+ identical bytes become repeat runs
/// (worth it once the run beats the 2-byte encoding); everything else
/// is literal. Long runs use the -1 extended form.
pub fn pack(input: &[u8]) -> Vec<u8> {
    let mut out = Vec::with_capacity(input.len() + input.len() / 127 + 1);
    let mut i = 0usize;
    let mut literal_start = 0usize;

    let flush_literals = |out: &mut Vec<u8>, from: usize, to: usize, input: &[u8]| {
        let mut s = from;
        while s < to {
            let n = (to - s).min(127);
            out.push(n as u8);
            out.extend_from_slice(&input[s..s + n]);
            s += n;
        }
    };

    while i < input.len() {
        let b = input[i];
        let mut run = 1usize;
        while i + run < input.len() && input[i + run] == b {
            run += 1;
        }
        if run >= 3 {
            flush_literals(&mut out, literal_start, i, input);
            let mut left = run;
            while left >= 3 {
                if left > 128 {
                    let n = left.min(u16::MAX as usize);
                    out.push(-1i8 as u8);
                    out.extend_from_slice(&(n as u16).to_le_bytes());
                    out.push(b);
                    left -= n;
                } else {
                    out.push((-(left as i32)) as i8 as u8);
                    out.push(b);
                    left = 0;
                }
            }
            i += run - left;
            // a residual run < 3 goes back to literals
            literal_start = i;
            i += left;
        } else {
            i += run;
        }
    }
    flush_literals(&mut out, literal_start, input.len(), input);
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn roundtrip_simple() {
        for case in [
            &b""[..],
            &b"a"[..],
            &b"abc"[..],
            &b"aaaa"[..],
            &b"abcaaaaaaaaaadef"[..],
            &[0u8; 1000][..],
        ] {
            assert_eq!(unpack(&pack(case)).unwrap(), case, "case {:?}", case);
        }
    }

    #[test]
    fn roundtrip_long_runs_use_extended_form() {
        let data = vec![7u8; 100_000];
        let packed = pack(&data);
        // the -1 form makes this tiny: ~7 bytes per 64K run
        assert!(packed.len() < 32, "packed to {} bytes", packed.len());
        assert_eq!(unpack(&packed).unwrap(), data);
    }

    #[test]
    fn unpack_classic_engine_stream() {
        // 3 literals, then 'x' repeated 5 times, then 2 literals -
        // the exact byte stream sqz.cpp's classic compressor emits
        let stream = [3, b'a', b'b', b'c', (-5i8) as u8, b'x', 2, b'd', b'e'];
        assert_eq!(unpack(&stream).unwrap(), b"abcxxxxxde");
    }

    #[test]
    fn unpack_extended_forms() {
        // -1: u16 length; -2: u32 length (Firebird 4+, sqz.cpp:434-443)
        let mut stream = vec![(-1i8) as u8];
        stream.extend_from_slice(&300u16.to_le_bytes());
        stream.push(b'z');
        assert_eq!(unpack(&stream).unwrap(), vec![b'z'; 300]);

        let mut stream = vec![(-2i8) as u8];
        stream.extend_from_slice(&70_000u32.to_le_bytes());
        stream.push(b'q');
        assert_eq!(unpack(&stream).unwrap(), vec![b'q'; 70_000]);
    }

    #[test]
    fn truncated_streams_error() {
        assert!(unpack(&[5, b'a']).is_none()); // promised 5 literals
        assert!(unpack(&[(-4i8) as u8]).is_none()); // run with no byte
        assert!(unpack(&[(-1i8) as u8, 0x01]).is_none()); // half a u16
    }

    /// Random-ish data survives round trips (deterministic xorshift,
    /// no external crates).
    #[test]
    fn roundtrip_pseudorandom() {
        let mut x: u32 = 0x1234_5678;
        let data: Vec<u8> = (0..50_000)
            .map(|_| {
                x ^= x << 13;
                x ^= x >> 17;
                x ^= x << 5;
                (x & 0xff) as u8
            })
            .collect();
        assert_eq!(unpack(&pack(&data)).unwrap(), data);
    }
}
