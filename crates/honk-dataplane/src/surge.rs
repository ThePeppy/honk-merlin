//! Subscription bodies: Surge `ss` lines, or plain and base64 lists of
//! `ss://` SIP002 links.
//!
//! The negative-lookahead filter used by the owner's profile is
//! `^(?!.*(剩余流量|距离下次|套餐到期)).*$`. The `regex` crate cannot express
//! that lookahead, so this parser accepts that one shape and drops a name
//! that contains any listed literal. SIP002 names are URL-decoded before
//! that check. The cache is rewritten as Surge lines either way.

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SurgeNode {
    pub name: String,
    pub host: String,
    pub port: u16,
    pub method: String,
    pub password: String,
}

pub fn keep_name(name: &str, pattern: &str) -> bool {
    let Some(words) = lookahead_words(pattern) else {
        return true;
    };
    !words.iter().any(|word| name.contains(word))
}

pub fn lookahead_words(pattern: &str) -> Option<Vec<String>> {
    let rest = pattern.strip_prefix("^(?!.*(")?.strip_suffix(")).*$")?;
    if rest.is_empty() {
        return None;
    }
    Some(rest.split('|').map(|word| word.to_string()).collect())
}

pub fn parse_ss_line(line: &str) -> Option<SurgeNode> {
    let parts = split_csv(line);
    if parts.len() < 4 || !parts[0].contains('=') {
        return None;
    }
    let (name, kind) = parts[0].split_once('=')?;
    if kind.trim() != "ss" {
        return None;
    }
    let name = unquote(name.trim());
    let host = unquote(parts[1].trim());
    let port: u16 = unquote(parts[2].trim()).parse().ok()?;
    let mut method = String::new();
    let mut password = String::new();
    for item in &parts[3..] {
        let (key, value) = item.split_once('=')?;
        match key.trim() {
            "encrypt-method" | "method" => method = unquote(value.trim()),
            "password" => password = unquote(value.trim()),
            _ => {}
        }
    }
    if name.is_empty() || host.is_empty() || method.is_empty() || port == 0 {
        return None;
    }
    Some(SurgeNode {
        name,
        host,
        port,
        method,
        password,
    })
}

pub struct SubscriptionImport {
    pub format: &'static str,
    pub nodes: usize,
    pub body: String,
}

/// Detect a Surge list or a SIP002 list, including a base64 blob of either,
/// drop names the policy regex rejects, and return Surge lines.
pub fn import_subscription(text: &str, pattern: &str) -> SubscriptionImport {
    let (decoded, source) = decode_blob(text);
    let mut saw_surge = false;
    let mut saw_sip = false;
    let mut kept = Vec::new();
    for line in source.lines() {
        let trimmed = line.trim();
        if trimmed.is_empty() || trimmed.starts_with('#') || trimmed.starts_with('[') {
            continue;
        }
        if let Some(node) = parse_ss_line(trimmed) {
            saw_surge = true;
            consider(&mut kept, node, pattern);
            continue;
        }
        for token in trimmed.split_whitespace() {
            let Some(index) = token.find("ss://") else {
                continue;
            };
            saw_sip = true;
            let Some(node) = parse_share_link(&token[index..]) else {
                continue;
            };
            consider(&mut kept, node, pattern);
        }
    }
    let mut body = String::new();
    for node in &kept {
        body.push_str(&surge_line(node));
        body.push('\n');
    }
    SubscriptionImport {
        format: format_name(decoded, saw_surge, saw_sip),
        nodes: kept.len(),
        body,
    }
}

pub fn filter_body(text: &str, pattern: &str) -> String {
    import_subscription(text, pattern).body
}

fn consider(kept: &mut Vec<SurgeNode>, node: SurgeNode, pattern: &str) {
    if keep_name(&node.name, pattern) && crate::ss::supported_method(&node.method) {
        kept.push(node);
    }
}

fn format_name(decoded: bool, surge: bool, sip: bool) -> &'static str {
    match (decoded, surge, sip) {
        (true, true, true) => "base64-mixed",
        (true, true, false) => "base64-surge",
        (true, false, true) => "base64-sip002",
        (false, true, true) => "mixed",
        (false, true, false) => "surge",
        (false, false, true) => "sip002",
        (true, false, false) => "base64",
        (false, false, false) => "empty",
    }
}

fn decode_blob(text: &str) -> (bool, String) {
    if looks_like_subscription(text) {
        return (false, text.to_string());
    }
    let compact: String = text.chars().filter(|char| !char.is_whitespace()).collect();
    if compact.is_empty() {
        return (false, String::new());
    }
    for engine in [
        base64::engine::general_purpose::STANDARD,
        base64::engine::general_purpose::STANDARD_NO_PAD,
        base64::engine::general_purpose::URL_SAFE,
        base64::engine::general_purpose::URL_SAFE_NO_PAD,
    ] {
        let Ok(bytes) = base64::Engine::decode(&engine, &compact) else {
            continue;
        };
        let Ok(decoded) = String::from_utf8(bytes) else {
            continue;
        };
        if looks_like_subscription(&decoded) {
            return (true, decoded);
        }
    }
    (false, text.to_string())
}

fn looks_like_subscription(text: &str) -> bool {
    text.contains("ss://")
        || text
            .lines()
            .any(|line| parse_ss_line(line.trim()).is_some())
}

fn parse_share_link(link: &str) -> Option<SurgeNode> {
    let link = link.trim_end_matches([',', ';', '"', '\'']);
    let mut diagnostics = Vec::new();
    let node =
        honk_config::node::Node::from_share_link_with_detailed_diagnostics(link, &mut diagnostics)
            .ok()?;
    let ss = node.shadowsocks()?;
    let method = ss.encryption.clone()?;
    let password = ss.password.clone()?;
    let host = if node.host.is_empty() {
        node.address.clone()
    } else {
        node.host.clone()
    };
    if host.is_empty() || node.port == 0 || node.name.is_empty() {
        return None;
    }
    Some(SurgeNode {
        name: node.name,
        host,
        port: node.port,
        method,
        password,
    })
}

fn surge_line(node: &SurgeNode) -> String {
    format!(
        "{} = ss, {}, {}, encrypt-method={}, password={}",
        surge_field(&node.name),
        surge_field(&node.host),
        node.port,
        surge_field(&node.method),
        surge_field(&node.password)
    )
}

fn surge_field(value: &str) -> String {
    if value.contains([',', ' ', '\'', '"', '=']) {
        if value.contains('\'') {
            format!("\"{value}\"")
        } else {
            format!("'{value}'")
        }
    } else {
        value.to_string()
    }
}

fn split_csv(line: &str) -> Vec<String> {
    let mut parts = Vec::new();
    let mut buf = String::new();
    let mut quote = None;
    for char in line.chars() {
        if let Some(mark) = quote {
            buf.push(char);
            if char == mark {
                quote = None;
            }
        } else if char == '\'' || char == '"' {
            quote = Some(char);
            buf.push(char);
        } else if char == ',' {
            parts.push(buf.trim().to_string());
            buf.clear();
        } else {
            buf.push(char);
        }
    }
    if !buf.trim().is_empty() {
        parts.push(buf.trim().to_string());
    }
    parts
}

fn unquote(value: &str) -> String {
    let value = value.trim();
    if value.len() >= 2 {
        let bytes = value.as_bytes();
        if (bytes[0] == b'\'' || bytes[0] == b'"') && bytes[0] == bytes[bytes.len() - 1] {
            return value[1..value.len() - 1].to_string();
        }
    }
    value.to_string()
}

#[cfg(test)]
mod tests {
    use super::*;

    const PATTERN: &str = r"^(?!.*(剩余流量|距离下次|套餐到期)).*$";

    #[test]
    fn info_nodes_are_removed_and_ss_nodes_stay() {
        let body = "\
Alpha = ss, 203.0.113.20, 1, encrypt-method=chacha20-ietf-poly1305, password=fake-alpha, udp-relay=true
剩余流量 = ss, 203.0.113.21, 1, encrypt-method=chacha20-ietf-poly1305, password=fake-info, udp-relay=true
Beta = ss, 203.0.113.23, 2, encrypt-method=chacha20-ietf-poly1305, password=fake-beta
";
        let filtered = filter_body(body, PATTERN);
        assert!(filtered.contains("Alpha"));
        assert!(filtered.contains("Beta"));
        assert!(!filtered.contains("剩余流量"));
        assert!(!filtered.contains("fake-info"));
        let imported = import_subscription(body, PATTERN);
        assert_eq!(imported.format, "surge");
        assert_eq!(imported.nodes, 2);
    }

    fn b64(text: &str) -> String {
        base64::Engine::encode(&base64::engine::general_purpose::STANDARD, text.as_bytes())
    }

    #[test]
    fn sip002_plain_userinfo_base64_and_encoded_names() {
        let userinfo = b64("chacha20-ietf-poly1305:fake-alpha");
        let userinfo_link = format!("ss://{userinfo}@203.0.113.20:8388#Alpha");
        let body = format!(
            "{userinfo_link}\nss://chacha20-ietf-poly1305:fake-beta@203.0.113.23:8388#Beta\nss://chacha20-ietf-poly1305:fake-hk@203.0.113.24:8388#HK%20One\nss://chacha20-ietf-poly1305:fake-info@203.0.113.21:8388#%E5%89%A9%E4%BD%99%E6%B5%81%E9%87%8F\nss://aes-256-gcm:fake-aes@203.0.113.25:8388#Aes\n"
        );
        let imported = import_subscription(&body, PATTERN);
        assert_eq!(imported.format, "sip002");
        assert_eq!(imported.nodes, 3);
        assert!(imported.body.contains("Alpha"));
        assert!(imported.body.contains("Beta"));
        assert!(imported.body.contains("HK One"));
        assert!(imported.body.contains("fake-alpha"));
        assert!(!imported.body.contains("剩余流量"));
        assert!(!imported.body.contains("fake-info"));
        assert!(!imported.body.contains("fake-aes"));
        assert!(!imported.body.contains("Aes"));
        let again = import_subscription(&imported.body, "");
        assert_eq!(again.format, "surge");
        assert_eq!(again.nodes, 3);
    }

    #[test]
    fn base64_blob_of_sip002_links_is_detected() {
        let links = "\
ss://chacha20-ietf-poly1305:fake-alpha@203.0.113.20:8388#Alpha
ss://chacha20-ietf-poly1305:fake-beta@203.0.113.23:8388#Beta
";
        let blob = b64(links);
        assert!(!blob.contains("ss://"));
        let imported = import_subscription(&blob, "");
        assert_eq!(imported.format, "base64-sip002");
        assert_eq!(imported.nodes, 2);
        assert!(imported.body.contains("203.0.113.20"));
        assert!(imported.body.contains("fake-beta"));
    }
}
