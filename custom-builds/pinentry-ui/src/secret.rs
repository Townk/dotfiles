//! The passphrase buffer, and the only place in this program that holds one.
//!
//! `docs/pinentry-ui-design.md` states eight rules for this memory. Five of them
//! are structural and live here; the rest are process-wide and live in
//! `hardening`.

use zeroize::Zeroize;

/// Bytes. A passphrase longer than this is refused rather than reallocated —
/// growing the buffer would copy the secret to a fresh allocation and leave the
/// old bytes behind unwiped, which is exactly the copy rule 4 forbids.
const CAPACITY: usize = 1024;

/// A fixed-capacity, locked, self-wiping passphrase buffer.
///
/// It deliberately implements neither `Debug` nor `Display`, and exposes no
/// accessor for its contents beyond the one the Assuan layer will need. That is
/// rule 8 expressed as a type: `println!("{pw:?}")` is a compile error rather
/// than a code review someone has to remember to do. Do not add a derive here.
pub struct Passphrase {
    buf: Vec<u8>,
    /// False when `mlock` was refused — see `Passphrase::new`.
    locked: bool,
}

impl Passphrase {
    pub fn new() -> Self {
        // Capacity is allocated once and never exceeded, so the pointer we lock
        // stays the pointer we write to for the lifetime of the buffer.
        let mut buf: Vec<u8> = Vec::with_capacity(CAPACITY);
        // SAFETY: the allocation is live and CAPACITY bytes long; mlock only
        // pins pages and never reads or writes them.
        let locked = unsafe { libc::mlock(buf.as_mut_ptr().cast(), CAPACITY) } == 0;
        Self { buf, locked }
    }

    /// Rule 6: a refused lock is reported, not fatal. Failing the prompt would
    /// deny the signature to protect against a weaker threat than the denial
    /// itself creates. Callers warn once; they must not abort.
    pub fn is_locked(&self) -> bool {
        self.locked
    }

    pub fn len(&self) -> usize {
        self.buf.len()
    }

    /// Number of characters, not bytes — what the masked field draws one bullet
    /// for. Counting lead bytes is enough: every UTF-8 character has exactly
    /// one, and anything the terminal hands us that is not valid UTF-8 is
    /// counted as its own bytes, which is the conservative direction.
    pub fn chars(&self) -> usize {
        self.buf.iter().filter(|b| (*b & 0xC0) != 0x80).count()
    }

    /// True when the byte was stored. False means the buffer is full, and the
    /// caller should tell the human rather than silently truncating a
    /// passphrase they believe they typed.
    pub fn push(&mut self, byte: u8) -> bool {
        if self.buf.len() == CAPACITY {
            return false;
        }
        self.buf.push(byte);
        true
    }

    /// Remove one whole character: the trailing UTF-8 continuation bytes and
    /// then the lead byte. Popping a single byte would split a multi-byte
    /// character and leave the buffer holding an invalid fragment the human
    /// cannot see and cannot delete.
    pub fn pop_char(&mut self) {
        while let Some(&b) = self.buf.last() {
            self.buf.pop();
            self.wipe_tail();
            if (b & 0xC0) != 0x80 {
                break;
            }
        }
    }

    /// Delete back to the previous run of spaces. Word-wise editing is unusual
    /// in a passphrase field, but Ctrl-W reaching the buffer as a literal
    /// control byte would be worse than handling it.
    pub fn pop_word(&mut self) {
        while !self.buf.is_empty() && self.buf.last() == Some(&b' ') {
            self.buf.pop();
            self.wipe_tail();
        }
        while !self.buf.is_empty() && self.buf.last() != Some(&b' ') {
            self.buf.pop();
            self.wipe_tail();
        }
    }

    pub fn clear(&mut self) {
        self.buf.zeroize();
        self.buf.clear();
    }

    /// Write the passphrase to `out` as Assuan `D` lines, percent-encoded.
    ///
    /// This is the one accessor the type promises, and it is a *writer* rather
    /// than a getter on purpose: returning `&[u8]` or a `String` would let the
    /// secret be copied into memory this module does not own and cannot wipe,
    /// which is rule 1. Encoding happens here, into a small buffer that is
    /// wiped before returning, so the plaintext never exists outside these
    /// pages.
    ///
    /// Assuan caps a line at 1000 bytes and `%` triples in the worst case, so a
    /// 1024-byte passphrase cannot go out in one line. Chunking is by *input*
    /// bytes, which keeps an escape from ever being split across two lines, and
    /// a reader concatenates `D` lines anyway.
    pub fn write_assuan_data(&self, out: &mut impl std::io::Write) -> std::io::Result<()> {
        const PER_LINE: usize = 256; // 256 * 3 + "D " is well inside 1000
        let mut enc: Vec<u8> = Vec::with_capacity(PER_LINE * 3 + 3);
        let result = (|| {
            for chunk in self.buf.chunks(PER_LINE) {
                enc.clear();
                enc.extend_from_slice(b"D ");
                for &b in chunk {
                    match b {
                        b'%' => enc.extend_from_slice(b"%25"),
                        b'\r' => enc.extend_from_slice(b"%0D"),
                        b'\n' => enc.extend_from_slice(b"%0A"),
                        _ => enc.push(b),
                    }
                }
                enc.push(b'\n');
                out.write_all(&enc)?;
            }
            Ok(())
        })();
        enc.zeroize();
        result
    }

    /// Write the passphrase the way an askpass caller reads it: the bytes, then
    /// a newline.
    ///
    /// The second permitted accessor, and a writer for the same reason as the
    /// first — handing back `&[u8]` would let the secret be copied somewhere
    /// this module cannot wipe. Nothing is encoded, so unlike the Assuan
    /// writer there is no intermediate buffer to wipe either.
    ///
    /// sudo and ssh read one line and strip the terminator, which makes a
    /// newline the one byte a secret cannot carry through this protocol. The
    /// field cannot produce one — Enter submits the dialog — so that is a
    /// property of the input, not a check to make here.
    pub fn write_askpass_line(&self, out: &mut impl std::io::Write) -> std::io::Result<()> {
        out.write_all(&self.buf)?;
        out.write_all(b"\n")
    }

    /// A byte popped from a `Vec` stays in the allocation past the new length,
    /// so every deletion has to overwrite the vacated slot. Without this an
    /// edited passphrase leaves its earlier keystrokes in memory until drop.
    fn wipe_tail(&mut self) {
        let len = self.buf.len();
        // SAFETY: `len` is within the allocation by construction — it is the
        // index just vacated by the pop that precedes every call.
        unsafe { std::ptr::write_volatile(self.buf.as_mut_ptr().add(len), 0) };
    }
}

impl Drop for Passphrase {
    fn drop(&mut self) {
        // Wipe the whole allocation, not just the live prefix: deletions leave
        // bytes above `len` and the volatile wipe above is per-slot.
        // SAFETY: CAPACITY bytes were reserved in `new` and never reallocated,
        // because `push` refuses to exceed them.
        unsafe {
            std::ptr::write_bytes(self.buf.as_mut_ptr(), 0, CAPACITY);
        }
        self.buf.zeroize();
        if self.locked {
            // SAFETY: same region locked in `new`, still live here.
            unsafe { libc::munlock(self.buf.as_ptr().cast(), CAPACITY) };
        }
    }
}
