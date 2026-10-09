//! Session keys, the sealed transport and framing — byte-for-byte what the Mac
//! (`SharedSecretKDF`, `EncryptedTransport`, `FrameCodec`) and Android
//! (`SessionKdf`, `EncryptedTransport`, `FrameCodec`) do. See docs/PROTOCOL.md.
//! The tests pin the same vectors their tests pin.

use chacha20poly1305::aead::{Aead, KeyInit};
use chacha20poly1305::{ChaCha20Poly1305, Key, Nonce};
use hkdf::Hkdf;
use sha2::{Digest, Sha256};
use tokio::io::{AsyncRead, AsyncReadExt, AsyncWrite, AsyncWriteExt};

/// Bytes each side contributes per connection. Not secret, only fresh.
pub const SALT_LEN: usize = 16;

/// Nonce byte 0. A hub always answers (responder); the phone always dials.
pub const DIR_RESPONDER: u8 = 0x00;
#[cfg_attr(not(test), allow(dead_code))] // the phone's side; used by the tests
pub const DIR_INITIATOR: u8 = 0x01;

/// Video keyframes are large; both apps cap a frame at 4 MB.
pub const MAX_FRAME: usize = 4 * 1024 * 1024;

pub fn random_salt() -> [u8; SALT_LEN] {
    rand::random()
}

/// HKDF-SHA256(raw X25519 output, salt "bridg-session", info initiator ‖ responder salt).
///
/// The identity keys are long-term, so the raw secret is the same every time;
/// only the per-connection salts keep the (key, nonce) sequence from repeating.
pub fn session_key(raw: &[u8; 32], initiator_salt: &[u8], responder_salt: &[u8]) -> [u8; 32] {
    let info = [initiator_salt, responder_salt].concat();
    let mut key = [0u8; 32];
    Hkdf::<Sha256>::new(Some(b"bridg-session"), raw)
        .expand(&info, &mut key)
        .expect("32 bytes is a valid HKDF-SHA256 length");
    key
}

/// Hex of the first 8 bytes of SHA-256(public key): the TXT `id` phones match on.
pub fn hub_tag(public_key: &[u8]) -> String {
    Sha256::digest(public_key)[..8].iter().map(|b| format!("{b:02x}")).collect()
}

/// One direction of a sealed connection. The reader and the writer each own
/// one, built from the same key: sealing touches only `sent`, opening only
/// `last_peer`.
pub struct Transport {
    cipher: ChaCha20Poly1305,
    send_dir: u8,
    sent: u64,
    last_peer: u64,
}

impl Transport {
    pub fn new(key: &[u8; 32], send_dir: u8) -> Self {
        Self { cipher: ChaCha20Poly1305::new(Key::from_slice(key)), send_dir, sent: 0, last_peer: 0 }
    }

    /// nonce (12) ‖ ciphertext ‖ tag (16). Nonce = [direction, 0, 0, 0, BE counter].
    pub fn seal(&mut self, plaintext: &[u8]) -> Vec<u8> {
        self.sent += 1;
        let mut nonce = [0u8; 12];
        nonce[0] = self.send_dir;
        nonce[4..].copy_from_slice(&self.sent.to_be_bytes());
        let mut out = nonce.to_vec();
        out.extend(self.cipher.encrypt(Nonce::from_slice(&nonce), plaintext).expect("chacha20poly1305 seal"));
        out
    }

    /// Refuses our own frames reflected back (both directions share the key),
    /// replays (TCP is ordered, so the counter must strictly rise), and
    /// forgeries. The counter only advances once the tag verifies — otherwise
    /// one junk frame with a huge counter would wedge every real one after it.
    pub fn open(&mut self, frame: &[u8]) -> Option<Vec<u8>> {
        if frame.len() < 12 + 16 || frame[0] == self.send_dir {
            return None;
        }
        let counter = u64::from_be_bytes(frame[4..12].try_into().ok()?);
        if counter <= self.last_peer {
            return None;
        }
        let plain = self.cipher.decrypt(Nonce::from_slice(&frame[..12]), &frame[12..]).ok()?;
        self.last_peer = counter;
        Some(plain)
    }
}

/// 4-byte big-endian length, then the payload. `Ok(None)` is a clean close.
pub async fn read_frame<R: AsyncRead + Unpin>(r: &mut R) -> std::io::Result<Option<Vec<u8>>> {
    let mut len = [0u8; 4];
    match r.read_exact(&mut len).await {
        Ok(_) => {}
        Err(e) if e.kind() == std::io::ErrorKind::UnexpectedEof => return Ok(None),
        Err(e) => return Err(e),
    }
    let len = u32::from_be_bytes(len) as usize;
    if len > MAX_FRAME {
        return Err(std::io::Error::new(std::io::ErrorKind::InvalidData, "frame over 4 MB"));
    }
    let mut buf = vec![0u8; len];
    r.read_exact(&mut buf).await?;
    Ok(Some(buf))
}

pub async fn write_frame<W: AsyncWrite + Unpin>(w: &mut W, payload: &[u8]) -> std::io::Result<()> {
    w.write_all(&(payload.len() as u32).to_be_bytes()).await?;
    w.write_all(payload).await?;
    w.flush().await
}

#[cfg(test)]
mod tests {
    use super::*;

    fn hex(b: &[u8]) -> String {
        b.iter().map(|x| format!("{x:02x}")).collect()
    }

    /// testHKDFMatchesTheVectorAndroidDerives on the Mac; same on Android.
    #[test]
    fn hkdf_matches_mac_and_android() {
        let ikm: [u8; 32] = core::array::from_fn(|i| i as u8);
        let init: Vec<u8> = (0xa0..=0xaf).collect();
        let resp: Vec<u8> = (0xb0..=0xbf).collect();
        assert_eq!(
            hex(&session_key(&ikm, &init, &resp)),
            "9bcc4b236bef52d412a912466352d92779a5e878648cf7f60f9c12f4c26e6b63"
        );
        assert_ne!(session_key(&ikm, &init, &resp), session_key(&ikm, &resp, &init));
    }

    /// testChaChaPolyWireFormatMatchesLibsodium on the Mac: the phone's first frame.
    #[test]
    fn opens_the_phones_first_frame() {
        let key: [u8; 32] = [
            0x7e, 0x6f, 0x4d, 0xdb, 0x23, 0x31, 0x99, 0x02, 0xfb, 0x5c, 0x5f, 0x3a, 0x72, 0xec, 0x81, 0xac,
            0x8a, 0x9d, 0xdf, 0x48, 0x47, 0x46, 0x3d, 0x09, 0x3f, 0xf4, 0x4f, 0xa7, 0x2d, 0xa1, 0xb3, 0xe3,
        ];
        let mut frame = vec![0x01, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0x01];
        frame.extend([
            0x52, 0x17, 0x4d, 0x74, 0x2b, 0x47, 0x91, 0x04, 0x77, 0xb5, 0x9c, 0x41, 0xbb, 0x84, 0xc0, 0xb6, 0x41,
            0x24, 0x29, 0x38, 0x38,
        ]);
        assert_eq!(Transport::new(&key, DIR_RESPONDER).open(&frame).as_deref(), Some(&b"bridg"[..]));
        // And sealing the same plaintext as the phone would reproduces it exactly.
        assert_eq!(Transport::new(&key, DIR_INITIATOR).seal(b"bridg"), frame);
    }

    #[test]
    fn rejects_replay_reflection_and_forgery() {
        let key = [0x42; 32];
        let mut hub = Transport::new(&key, DIR_RESPONDER);
        let mut phone_rx = Transport::new(&key, DIR_INITIATOR);
        let one = hub.seal(b"one");
        let two = hub.seal(b"two");
        assert_eq!(phone_rx.open(&one).as_deref(), Some(&b"one"[..]));
        assert_eq!(phone_rx.open(&two).as_deref(), Some(&b"two"[..]));
        assert!(phone_rx.open(&one).is_none(), "replay");

        let mut hub_rx = Transport::new(&key, DIR_RESPONDER);
        assert!(hub_rx.open(&hub.seal(b"mine")).is_none(), "reflection");

        let mut forged = vec![0x01, 0, 0, 0, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff];
        forged.extend([0xab; 32]);
        assert!(hub_rx.open(&forged).is_none());
        let mut phone = Transport::new(&key, DIR_INITIATOR);
        assert_eq!(hub_rx.open(&phone.seal(b"real")).as_deref(), Some(&b"real"[..]), "forgery must not advance the counter");
    }

    /// testHubTagMatchesTheAndroidVector / HubTagTest.
    #[test]
    fn hub_tag_matches_mac_and_android() {
        let key: Vec<u8> = (0..32).collect();
        assert_eq!(hub_tag(&key), "630dcd2966c43366");
    }

    #[tokio::test]
    async fn frames_round_trip_and_cap() {
        let mut buf = Vec::new();
        write_frame(&mut buf, b"abc").await.unwrap();
        write_frame(&mut buf, b"").await.unwrap();
        let mut r = &buf[..];
        assert_eq!(read_frame(&mut r).await.unwrap().as_deref(), Some(&b"abc"[..]));
        assert_eq!(read_frame(&mut r).await.unwrap().as_deref(), Some(&b""[..]));
        assert!(read_frame(&mut r).await.unwrap().is_none());

        let huge = ((MAX_FRAME + 1) as u32).to_be_bytes();
        assert!(read_frame(&mut &huge[..]).await.is_err());
    }
}
