//! Surge `ss` lines used by a policy-path body.
//!
//! The negative-lookahead filter used by the owner's profile is
//! `^(?!.*(剩余流量|距离下次|套餐到期)).*$`. The `regex` crate cannot express
//! that lookahead, so this parser accepts that one shape and drops a name
//! that contains any listed literal.

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

pub fn filter_body(text: &str, pattern: &str) -> String {
    let mut out = String::new();
    for line in text.lines() {
        let trimmed = line.trim();
        if trimmed.is_empty() || trimmed.starts_with('#') || trimmed.starts_with('[') {
            continue;
        }
        if let Some(node) = parse_ss_line(trimmed)
            && keep_name(&node.name, pattern)
        {
            out.push_str(trimmed);
            out.push('\n');
        }
    }
    out
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
    }
}
