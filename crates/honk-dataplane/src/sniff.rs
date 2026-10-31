//! Read a domain from the first client bytes.
//!
//! TLS ClientHello SNI and a plaintext HTTP Host header are the only sources.
//! The router DNS resolver is not asked. Bytes already read have to be sent
//! with the proxied or direct stream.

use tokio::io::AsyncReadExt;

pub async fn read_prelude(stream: &mut tokio::net::TcpStream) -> Vec<u8> {
    let mut buf = vec![0u8; 4096];
    match tokio::time::timeout(std::time::Duration::from_millis(200), stream.read(&mut buf)).await {
        Ok(Ok(n)) if n > 0 => {
            buf.truncate(n);
            buf
        }
        _ => Vec::new(),
    }
}

pub struct Sniffed {
    pub sni: Option<String>,
    pub host: Option<String>,
}

impl Sniffed {
    pub fn domain(&self) -> Option<String> {
        self.sni.clone().or_else(|| self.host.clone())
    }
}

pub fn sniff_parts(buf: &[u8]) -> Sniffed {
    if let Some(name) = sni(buf) {
        Sniffed {
            sni: Some(clean(name)),
            host: None,
        }
    } else if let Some(name) = http_host(buf) {
        Sniffed {
            sni: None,
            host: Some(clean(name)),
        }
    } else {
        Sniffed {
            sni: None,
            host: None,
        }
    }
}

fn clean(name: String) -> String {
    name.trim_end_matches('.').to_string()
}

fn sni(buf: &[u8]) -> Option<String> {
    if buf.len() < 5 || buf[0] != 0x16 {
        return None;
    }
    let mut index = 5;
    if *buf.get(index)? != 0x01 {
        return None;
    }
    index += 4 + 2 + 32;
    let session = *buf.get(index)? as usize;
    index += 1 + session;
    let ciphers = u16::from_be_bytes([*buf.get(index)?, *buf.get(index + 1)?]) as usize;
    index += 2 + ciphers;
    let compression = *buf.get(index)? as usize;
    index += 1 + compression;
    let extensions = u16::from_be_bytes([*buf.get(index)?, *buf.get(index + 1)?]) as usize;
    index += 2;
    let end = index.checked_add(extensions)?.min(buf.len());
    while index + 4 <= end {
        let kind = u16::from_be_bytes([buf[index], buf[index + 1]]);
        let len = u16::from_be_bytes([buf[index + 2], buf[index + 3]]) as usize;
        index += 4;
        let body = buf.get(index..index + len)?;
        if kind == 0 {
            return sni_name(body);
        }
        index += len;
    }
    None
}

fn sni_name(body: &[u8]) -> Option<String> {
    if body.len() < 5 {
        return None;
    }
    let list = u16::from_be_bytes([body[0], body[1]]) as usize;
    let mut index: usize = 2;
    let end = index.checked_add(list)?.min(body.len());
    while index + 3 <= end {
        let typ = body[index];
        let len = u16::from_be_bytes([body[index + 1], body[index + 2]]) as usize;
        index += 3;
        let name = body.get(index..index + len)?;
        if typ == 0 {
            let text = String::from_utf8(name.to_vec()).ok()?;
            if !text.is_empty() {
                return Some(text);
            }
        }
        index += len;
    }
    None
}

fn http_host(buf: &[u8]) -> Option<String> {
    let text = std::str::from_utf8(buf).ok()?;
    let line = text.lines().next()?;
    let mut parts = line.split_whitespace();
    let method = parts.next()?;
    if !matches!(
        method,
        "GET" | "POST" | "HEAD" | "PUT" | "DELETE" | "OPTIONS" | "CONNECT" | "PATCH"
    ) {
        return None;
    }
    for header in text.split("\r\n").skip(1) {
        let (name, value) = header.split_once(':')?;
        if name.eq_ignore_ascii_case("host") {
            let host = value.trim();
            let host = host.split(':').next()?.trim();
            if !host.is_empty() {
                return Some(host.to_string());
            }
        }
    }
    None
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn reads_sni() {
        let name = b"example.com";
        let mut ext = vec![0, 0, 0, (name.len() + 5) as u8];
        ext.extend_from_slice(&(name.len() as u16 + 3).to_be_bytes());
        ext.push(0);
        ext.extend_from_slice(&(name.len() as u16).to_be_bytes());
        ext.extend_from_slice(name);
        let mut hello = vec![0x16, 0x03, 0x01, 0, 0, 0x01, 0, 0, 0];
        hello.extend_from_slice(&[0x03, 0x03]);
        hello.extend_from_slice(&[0u8; 32]);
        hello.push(0);
        hello.extend_from_slice(&0u16.to_be_bytes());
        hello.push(0);
        hello.extend_from_slice(&(ext.len() as u16).to_be_bytes());
        hello.extend_from_slice(&ext);
        let record_len = (hello.len() - 5) as u16;
        hello[3..5].copy_from_slice(&record_len.to_be_bytes());
        let hs_len = (hello.len() - 9) as u32;
        hello[6] = (hs_len >> 16) as u8;
        hello[7] = (hs_len >> 8) as u8;
        hello[8] = hs_len as u8;
        assert_eq!(sniff_parts(&hello).domain().as_deref(), Some("example.com"));
    }

    #[test]
    fn reads_http_host_without_port() {
        let raw = b"GET / HTTP/1.1\r\nHost: Example.COM:80\r\n\r\n";
        assert_eq!(sniff_parts(raw).domain().as_deref(), Some("Example.COM"));
    }
}
