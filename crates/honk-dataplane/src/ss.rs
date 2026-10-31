//! Legacy Shadowsocks AEAD TCP, the same construction as
//! `honk-outbound`'s `ShadowsocksHandler::master_key` and `seal_chunks_into`:
//! EVP_BytesToKey, HKDF-SHA1 with info `ss-subkey`, then length and payload
//! chunks. ChaCha20-Poly1305 only; this binary does not link BoringSSL.

use std::io;

use chacha20poly1305::aead::Aead;
use chacha20poly1305::{ChaCha20Poly1305, KeyInit, Nonce};
use hkdf::Hkdf;
use md5::{Digest, Md5};
use rand::Rng;
use sha1::Sha1;
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::TcpStream;

const INFO: &[u8] = b"ss-subkey";
const KEY_LEN: usize = 32;
const TAG_LEN: usize = 16;
const CHUNK_MAX: usize = 0x3FFF;

struct Cipher {
    inner: ChaCha20Poly1305,
}

impl Cipher {
    fn new(subkey: &[u8; KEY_LEN]) -> Self {
        Self {
            inner: ChaCha20Poly1305::new(subkey.into()),
        }
    }

    fn seal(&self, nonce: &mut [u8], plain: &[u8], out: &mut Vec<u8>) -> io::Result<()> {
        let nonce_bytes: [u8; 12] = nonce.try_into().map_err(|_| io::Error::other("nonce"))?;
        let sealed = self
            .inner
            .encrypt(&Nonce::from(nonce_bytes), plain)
            .map_err(|_| io::Error::other("shadowsocks seal"))?;
        out.extend_from_slice(&sealed);
        increment(nonce);
        Ok(())
    }

    fn open<'a>(&self, nonce: &mut [u8], buf: &'a mut [u8]) -> io::Result<&'a [u8]> {
        let nonce_bytes: [u8; 12] = nonce.try_into().map_err(|_| io::Error::other("nonce"))?;
        let plain = self
            .inner
            .decrypt(&Nonce::from(nonce_bytes), buf as &[u8])
            .map_err(|_| io::Error::other("shadowsocks open"))?;
        let len = plain.len();
        buf[..len].copy_from_slice(&plain);
        increment(nonce);
        Ok(&buf[..len])
    }
}

fn master_key(password: &str) -> [u8; KEY_LEN] {
    let mut key = Vec::with_capacity(KEY_LEN);
    let mut last = Vec::new();
    while key.len() < KEY_LEN {
        let mut hasher = Md5::new();
        hasher.update(&last);
        hasher.update(password.as_bytes());
        last = hasher.finalize().to_vec();
        key.extend_from_slice(&last);
    }
    key.truncate(KEY_LEN);
    key.try_into().expect("key length")
}

fn subkey(master: &[u8], salt: &[u8]) -> [u8; KEY_LEN] {
    let mut out = [0u8; KEY_LEN];
    Hkdf::<Sha1>::new(Some(salt), master)
        .expand(INFO, &mut out)
        .expect("hkdf length");
    out
}

fn increment(nonce: &mut [u8]) {
    for byte in nonce.iter_mut() {
        if *byte == 0xff {
            *byte = 0;
        } else {
            *byte += 1;
            break;
        }
    }
}

fn seal_payload(
    cipher: &Cipher,
    nonce: &mut [u8],
    payload: &[u8],
    out: &mut Vec<u8>,
) -> io::Result<()> {
    let mut offset = 0;
    while offset < payload.len() {
        let end = (offset + CHUNK_MAX).min(payload.len());
        let chunk = &payload[offset..end];
        cipher.seal(nonce, &(chunk.len() as u16).to_be_bytes(), out)?;
        cipher.seal(nonce, chunk, out)?;
        offset = end;
    }
    Ok(())
}

pub fn address_header(host: &str, port: u16) -> io::Result<Vec<u8>> {
    let mut out = Vec::new();
    if let Ok(ip) = host.parse::<std::net::Ipv4Addr>() {
        out.push(0x01);
        out.extend_from_slice(&ip.octets());
    } else if let Ok(ip) = host.parse::<std::net::Ipv6Addr>() {
        out.push(0x04);
        out.extend_from_slice(&ip.octets());
    } else {
        if host.len() > 255 {
            return Err(io::Error::other("domain too long"));
        }
        out.push(0x03);
        out.push(host.len() as u8);
        out.extend_from_slice(host.as_bytes());
    }
    out.extend_from_slice(&port.to_be_bytes());
    Ok(out)
}

pub fn supported_method(method: &str) -> bool {
    matches!(
        method.to_ascii_lowercase().as_str(),
        "chacha20-ietf-poly1305" | "chacha20-poly1305"
    )
}

pub async fn relay(
    server_host: &str,
    server_port: u16,
    password: &str,
    host: &str,
    port: u16,
    mut client: TcpStream,
    prelude: &[u8],
) -> io::Result<()> {
    let mut upstream = TcpStream::connect((server_host, server_port)).await?;
    let master = master_key(password);
    let mut salt = [0u8; KEY_LEN];
    rand::rng().fill_bytes(&mut salt);
    let cipher = Cipher::new(&subkey(&master, &salt));
    let mut nonce = [0u8; 12];
    let mut header = address_header(host, port)?;
    header.extend_from_slice(prelude);
    let mut sealed = Vec::new();
    seal_payload(&cipher, &mut nonce, &header, &mut sealed)?;
    upstream.write_all(&salt).await?;
    upstream.write_all(&sealed).await?;

    let mut recv_salt = [0u8; KEY_LEN];
    let mut recv_filled = 0usize;
    let mut recv_cipher: Option<Cipher> = None;
    let mut recv_nonce = [0u8; 12];
    let mut pending_len: Option<u16> = None;
    let mut carry = Vec::new();
    let mut client_buf = [0u8; 16 * 1024];
    let mut server_buf = [0u8; 16 * 1024];

    loop {
        tokio::select! {
            read = client.read(&mut client_buf) => {
                let n = read?;
                if n == 0 {
                    let _ = upstream.shutdown().await;
                    break;
                }
                let mut out = Vec::new();
                seal_payload(&cipher, &mut nonce, &client_buf[..n], &mut out)?;
                upstream.write_all(&out).await?;
            }
            read = upstream.read(&mut server_buf) => {
                let n = read?;
                if n == 0 {
                    let _ = client.shutdown().await;
                    break;
                }
                let mut incoming = carry.split_off(0);
                incoming.extend_from_slice(&server_buf[..n]);
                if recv_cipher.is_none() {
                    let need = KEY_LEN - recv_filled;
                    let take = need.min(incoming.len());
                    recv_salt[recv_filled..recv_filled + take].copy_from_slice(&incoming[..take]);
                    recv_filled += take;
                    incoming.drain(..take);
                    if recv_filled == KEY_LEN {
                        recv_cipher = Some(Cipher::new(&subkey(&master, &recv_salt)));
                    }
                }
                if let Some(recv) = recv_cipher.as_ref() {
                    let plain = open_chunks(recv, &mut recv_nonce, &mut pending_len, &mut incoming)?;
                    if !plain.is_empty() {
                        client.write_all(&plain).await?;
                    }
                }
                carry = incoming;
            }
        }
    }
    Ok(())
}

fn open_chunks(
    cipher: &Cipher,
    nonce: &mut [u8],
    pending_len: &mut Option<u16>,
    incoming: &mut Vec<u8>,
) -> io::Result<Vec<u8>> {
    let mut plain = Vec::new();
    let mut pos = 0;
    while pos < incoming.len() {
        let len = if let Some(len) = *pending_len {
            len as usize
        } else {
            if incoming.len() - pos < 2 + TAG_LEN {
                break;
            }
            let mut field = incoming[pos..pos + 2 + TAG_LEN].to_vec();
            let opened = cipher.open(nonce, &mut field)?;
            if opened.len() != 2 {
                return Err(io::Error::other("short length"));
            }
            let len = u16::from_be_bytes([opened[0], opened[1]]) as usize;
            *pending_len = Some(len as u16);
            pos += 2 + TAG_LEN;
            len
        };
        if incoming.len() - pos < len + TAG_LEN {
            break;
        }
        let mut chunk = incoming[pos..pos + len + TAG_LEN].to_vec();
        let opened = cipher.open(nonce, &mut chunk)?;
        plain.extend_from_slice(opened);
        pos += len + TAG_LEN;
        *pending_len = None;
    }
    incoming.drain(..pos);
    Ok(plain)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn chacha_chunks_round_trip() {
        let master = master_key("fake-password");
        let salt = [7u8; KEY_LEN];
        let send = Cipher::new(&subkey(&master, &salt));
        let recv = Cipher::new(&subkey(&master, &salt));
        let mut nonce = [0u8; 12];
        let mut recv_nonce = [0u8; 12];
        let mut out = Vec::new();
        seal_payload(&send, &mut nonce, b"hello", &mut out).unwrap();
        let mut pending = None;
        let mut buf = out;
        let plain = open_chunks(&recv, &mut recv_nonce, &mut pending, &mut buf).unwrap();
        assert_eq!(plain, b"hello");
        assert!(buf.is_empty());
    }

    #[test]
    fn address_header_is_socks_ipv4() {
        let header = address_header("203.0.113.10", 443).unwrap();
        assert_eq!(header, [1, 203, 0, 113, 10, 1, 187]);
    }

    #[test]
    fn other_methods_are_refused() {
        assert!(supported_method("chacha20-ietf-poly1305"));
        assert!(!supported_method("aes-256-gcm"));
    }
}
