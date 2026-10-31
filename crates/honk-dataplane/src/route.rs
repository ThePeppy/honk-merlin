//! Match a redirected TCP flow against a dae file and choose direct, block,
//! or one Shadowsocks node.
//!
//! GeoIP and geosite conditions are kept in the file and do not match here:
//! this process does not load `geoip.dat` or `geosite.dat`. DNS stays on the
//! router's existing resolver; a domain is used only when sniffing found one.

use std::collections::HashMap;
use std::net::{IpAddr, SocketAddr};
#[cfg(unix)]
use std::os::unix::fs::PermissionsExt;
use std::path::Path;
use std::sync::Mutex;

use honk_config::parser::parse_dae_config;
use honk_config::routing::{RoutingCondition, RoutingNotCondition, RoutingRule};
use ipnet::IpNet;

use crate::ss;
use crate::surge::{self, SurgeNode};

#[derive(Clone)]
struct Node {
    host: String,
    port: u16,
    method: String,
    password: String,
}

#[derive(Clone)]
enum Member {
    Direct,
    Block,
    Pool,
    Name(String),
}

struct Loaded {
    rules: Vec<RoutingRule>,
    fallback: String,
    groups: HashMap<String, Vec<Member>>,
    defaults: HashMap<String, String>,
    nodes: HashMap<String, Node>,
    order: Vec<String>,
}

pub struct Decision {
    pub kind: DecisionKind,
    pub sni: String,
    pub host: String,
    pub rule: String,
    pub group: String,
    pub node: String,
}

#[derive(Debug)]
pub struct ConfigReport {
    pub nodes: usize,
    pub groups: usize,
    pub rules: usize,
    pub mode: u32,
    pub uid: u32,
    pub subscription: bool,
}

impl ConfigReport {
    pub fn log_line(&self, path: &Path) -> String {
        format!(
            "config loaded path={} mode={:03o} uid={} nodes={} groups={} rules={}",
            path.display(),
            self.mode,
            self.uid,
            self.nodes,
            self.groups,
            self.rules
        )
    }
}

impl Decision {
    pub fn log_line(&self) -> String {
        format!(
            "decision sni={} host={} rule={} group={} node={}",
            field(&self.sni),
            field(&self.host),
            field(&self.rule),
            field(&self.group),
            field(&self.node)
        )
    }
}

fn field(value: &str) -> &str {
    if value.is_empty() { "-" } else { value }
}

pub enum DecisionKind {
    Direct,
    Block,
    Proxy {
        server_host: String,
        server_port: u16,
        password: String,
    },
}

static LOADED: Mutex<Option<(u128, Loaded)>> = Mutex::new(None);

pub fn load_configured(
    path: &Path,
    cache: Option<&Path>,
    selections: &Path,
) -> anyhow::Result<ConfigReport> {
    let meta = std::fs::metadata(path)?;
    let text = std::fs::read_to_string(path)?;
    let config = parse_dae_config(&text)?;
    let loaded = build_loaded(&text, cache, selections)?;
    let report = ConfigReport {
        nodes: loaded.nodes.len(),
        groups: loaded.groups.len(),
        rules: loaded.rules.len(),
        mode: meta.permissions().mode() & 0o777,
        uid: file_uid(&meta),
        subscription: !config.subscriptions.is_empty(),
    };
    if report.subscription && report.nodes == 0 {
        anyhow::bail!("subscription produced no shadowsocks nodes");
    }
    *LOADED.lock().expect("route lock") = Some((0, loaded));
    Ok(report)
}

fn file_uid(meta: &std::fs::Metadata) -> u32 {
    #[cfg(unix)]
    {
        std::os::unix::fs::MetadataExt::uid(meta)
    }
    #[cfg(not(unix))]
    {
        let _ = meta;
        0
    }
}

pub fn reload(path: &Path, cache: Option<&Path>, selections: &Path) -> anyhow::Result<()> {
    let text = std::fs::read_to_string(path)?;
    let loaded = build_loaded(&text, cache, selections)?;
    *LOADED.lock().expect("route lock") = Some((0, loaded));
    Ok(())
}

fn build_loaded(text: &str, cache: Option<&Path>, selections: &Path) -> anyhow::Result<Loaded> {
    let config = parse_dae_config(text)?;
    let notes = notes(text);
    let mut nodes = HashMap::new();
    let mut order = Vec::new();
    if let Some(cache) = cache.filter(|path| path.is_file()) {
        for node in surge::filter_body(
            &std::fs::read_to_string(cache)?,
            notes.regex.as_deref().unwrap_or(""),
        )
        .lines()
        .filter_map(surge::parse_ss_line)
        {
            push_node(&mut nodes, &mut order, node);
        }
    }
    if order.is_empty() {
        for node in &config.nodes {
            let Some(ss) = node.shadowsocks() else {
                continue;
            };
            let Some(method) = ss.encryption.as_deref() else {
                continue;
            };
            let Some(password) = ss.password.clone() else {
                continue;
            };
            if !ss::supported_method(method) {
                continue;
            }
            let host = if node.host.is_empty() {
                node.address.clone()
            } else {
                node.host.clone()
            };
            push_node(
                &mut nodes,
                &mut order,
                SurgeNode {
                    name: node.name.clone(),
                    host,
                    port: node.port,
                    method: method.to_string(),
                    password,
                },
            );
        }
    }
    let selections = read_selections(selections);
    let mut groups = HashMap::new();
    let mut defaults = HashMap::new();
    for group in &config.groups {
        let members = if let Some(listed) = notes.members.get(&group.name) {
            listed.clone()
        } else {
            let mut members = Vec::new();
            for nested in &group.groups {
                members.push(Member::Name(nested.clone()));
            }
            for filter in &group.filters {
                members.extend(members_from_filter(filter));
            }
            members
        };
        if let Some(choice) = selections
            .get(&group.name)
            .cloned()
            .or_else(|| group.default.clone())
        {
            defaults.insert(group.name.clone(), choice);
        }
        groups.insert(group.name.clone(), members);
    }
    Ok(Loaded {
        rules: config.routing.rules.clone(),
        fallback: config.routing.default_outbound.clone(),
        groups,
        defaults,
        nodes,
        order,
    })
}

fn push_node(nodes: &mut HashMap<String, Node>, order: &mut Vec<String>, node: SurgeNode) {
    order.push(node.name.clone());
    nodes.insert(
        node.name.clone(),
        Node {
            host: node.host,
            port: node.port,
            method: node.method,
            password: node.password,
        },
    );
}

struct Notes {
    regex: Option<String>,
    members: HashMap<String, Vec<Member>>,
}

fn notes(text: &str) -> Notes {
    let mut regex = None;
    let mut members = HashMap::new();
    for line in text.lines() {
        let line = line.trim();
        if let Some(rest) = line.strip_prefix("# merlin-policy-regex:") {
            regex = Some(rest.trim().to_string());
        } else if let Some(rest) = line.strip_prefix("# merlin-members:")
            && let Some((name, list)) = rest.split_once('=')
        {
            members.insert(name.trim().to_string(), member_list(list));
        }
    }
    Notes { regex, members }
}

fn member_list(list: &str) -> Vec<Member> {
    list.split('|')
        .filter(|item| !item.is_empty())
        .map(|item| {
            if let Some(tag) = item.strip_prefix('@') {
                let _ = tag;
                Member::Pool
            } else if item == "direct" {
                Member::Direct
            } else if item == "block" {
                Member::Block
            } else {
                Member::Name(item.to_string())
            }
        })
        .collect()
}

fn members_from_filter(filter: &str) -> Vec<Member> {
    let filter = filter.trim();
    if let Some(inner) = filter
        .strip_prefix("name(")
        .and_then(|text| text.strip_suffix(')'))
    {
        return split_args(inner)
            .into_iter()
            .map(|name| match name.as_str() {
                "direct" => Member::Direct,
                "block" => Member::Block,
                other => Member::Name(other.to_string()),
            })
            .collect();
    }
    if filter.starts_with("subtag(") {
        return vec![Member::Pool];
    }
    Vec::new()
}

fn split_args(inner: &str) -> Vec<String> {
    inner
        .split(',')
        .map(|part| part.trim().trim_matches('\'').trim_matches('"').to_string())
        .filter(|part| !part.is_empty())
        .collect()
}

fn read_selections(path: &Path) -> HashMap<String, String> {
    let mut map = HashMap::new();
    let Ok(text) = std::fs::read_to_string(path) else {
        return map;
    };
    for line in text.lines() {
        let Some((group, choice)) = line.split_once(' ') else {
            continue;
        };
        let choice = choice.trim();
        if group
            .chars()
            .all(|ch| ch.is_ascii_alphanumeric() || ch == '_')
            && !choice.is_empty()
        {
            map.insert(group.to_string(), choice.to_string());
        }
    }
    map
}

pub fn decide(
    path: &Path,
    cache: Option<&Path>,
    selections: &Path,
    query: &Query,
    sni: &str,
    host: &str,
) -> anyhow::Result<Decision> {
    if LOADED.lock().expect("route lock").is_none() {
        reload(path, cache, selections)?;
    }
    let guard = LOADED.lock().expect("route lock");
    let loaded = &guard.as_ref().expect("loaded").1;
    Ok(explain(loaded, query, sni, host))
}

fn explain(loaded: &Loaded, query: &Query, sni: &str, host: &str) -> Decision {
    let (target, rule) = match_rule(loaded, query);
    let group = if loaded.groups.contains_key(&target) {
        target.clone()
    } else {
        String::new()
    };
    let leaf = resolve(loaded, &target, 0).unwrap_or(Leaf {
        kind: DecisionKind::Block,
        node: "block".to_string(),
    });
    Decision {
        kind: leaf.kind,
        sni: sni.to_string(),
        host: host.to_string(),
        rule,
        group,
        node: leaf.node,
    }
}

pub struct Query {
    pub domain: Option<String>,
    pub dest: SocketAddr,
    pub src: SocketAddr,
}

fn match_rule(loaded: &Loaded, query: &Query) -> (String, String) {
    for rule in &loaded.rules {
        if rule_matches(&rule.condition, query) {
            let label = format!(
                "{}->{}",
                matched_label(&rule.condition, query),
                rule.outbound.as_str()
            );
            return (rule.outbound.as_str().to_string(), label);
        }
    }
    (
        loaded.fallback.clone(),
        format!("fallback->{}", loaded.fallback),
    )
}

fn matched_label(condition: &RoutingCondition, query: &Query) -> String {
    if let Some(domain) = query.domain.as_deref() {
        if let Some(item) = condition
            .domain
            .iter()
            .find(|item| item.eq_ignore_ascii_case(domain))
        {
            return format!("domain(full:{item})");
        }
        if let Some(item) = condition
            .domain_suffix
            .iter()
            .find(|item| suffix_match(domain, item))
        {
            return format!("domain(suffix:{item})");
        }
        if let Some(item) = condition.domain_keyword.iter().find(|item| {
            domain
                .to_ascii_lowercase()
                .contains(&item.to_ascii_lowercase())
        }) {
            return format!("domain(keyword:{item})");
        }
    }
    if let Some(item) = condition
        .ip
        .iter()
        .find(|item| cidr_contains(item, query.dest.ip()))
    {
        return format!("dip({item})");
    }
    if let Some(item) = condition
        .port
        .iter()
        .find(|item| port_item(item, query.dest.port()))
    {
        return format!("dport({item})");
    }
    "match".to_string()
}

fn rule_matches(condition: &RoutingCondition, query: &Query) -> bool {
    fields_match(condition, query) && !negated_hit(&condition.not, query)
}

fn fields_match(condition: &RoutingCondition, query: &Query) -> bool {
    domain_ok(
        &condition.domain,
        &condition.domain_suffix,
        &condition.domain_keyword,
        &condition.domain_regex,
        &condition.geosite,
        query.domain.as_deref(),
    ) && ip_ok(&condition.ip, &condition.geo_ip, query.dest.ip())
        && ip_ok(&condition.source_ip, &[], query.src.ip())
        && port_ok(&condition.port, query.dest.port())
        && port_ok(&condition.source_port, query.src.port())
        && proto_ok(&condition.protocol)
}

fn negated_hit(not: &RoutingNotCondition, query: &Query) -> bool {
    let positive = RoutingCondition {
        domain: not.domain.clone(),
        domain_suffix: not.domain_suffix.clone(),
        domain_keyword: not.domain_keyword.clone(),
        domain_regex: not.domain_regex.clone(),
        ip: not.ip.clone(),
        source_ip: not.source_ip.clone(),
        port: not.port.clone(),
        source_port: not.source_port.clone(),
        protocol: not.protocol.clone(),
        process_name: Vec::new(),
        mac: Vec::new(),
        geo_ip: not.geo_ip.clone(),
        geosite: not.geosite.clone(),
        ip_version: Vec::new(),
        dscp: Vec::new(),
        not: RoutingNotCondition::default(),
    };
    let domain_set = !positive.domain.is_empty()
        || !positive.domain_suffix.is_empty()
        || !positive.domain_keyword.is_empty()
        || !positive.domain_regex.is_empty()
        || !positive.geosite.is_empty();
    let other = !positive.ip.is_empty()
        || !positive.geo_ip.is_empty()
        || !positive.source_ip.is_empty()
        || !positive.port.is_empty()
        || !positive.source_port.is_empty()
        || !positive.protocol.is_empty();
    if !domain_set && !other {
        return false;
    }
    fields_match(&positive, query)
}

fn domain_ok(
    full: &[String],
    suffix: &[String],
    keyword: &[String],
    regex: &[String],
    geosite: &[String],
    domain: Option<&str>,
) -> bool {
    if full.is_empty()
        && suffix.is_empty()
        && keyword.is_empty()
        && regex.is_empty()
        && geosite.is_empty()
    {
        return true;
    }
    // No geosite database, and domain regex is left for honk-core.
    if !geosite.is_empty()
        || !regex.is_empty() && full.is_empty() && suffix.is_empty() && keyword.is_empty()
    {
        return false;
    }
    let Some(domain) = domain else {
        return false;
    };
    let domain = domain.trim_end_matches('.');
    full.iter().any(|item| item.eq_ignore_ascii_case(domain))
        || suffix.iter().any(|item| suffix_match(domain, item))
        || keyword.iter().any(|item| {
            domain
                .to_ascii_lowercase()
                .contains(&item.to_ascii_lowercase())
        })
}

fn suffix_match(domain: &str, suffix: &str) -> bool {
    let suffix = suffix.trim_start_matches('.').trim_end_matches('.');
    domain.eq_ignore_ascii_case(suffix)
        || domain.len() > suffix.len()
            && domain.as_bytes()[domain.len() - suffix.len() - 1] == b'.'
            && domain[domain.len() - suffix.len()..].eq_ignore_ascii_case(suffix)
}

fn ip_ok(nets: &[String], geo: &[String], ip: IpAddr) -> bool {
    if nets.is_empty() && geo.is_empty() {
        return true;
    }
    if !geo.is_empty() {
        return false;
    }
    nets.iter().any(|item| cidr_contains(item, ip))
}

fn cidr_contains(item: &str, ip: IpAddr) -> bool {
    if let Ok(net) = item.parse::<IpNet>() {
        return net.contains(&ip);
    }
    if let Ok(addr) = item.parse::<IpAddr>() {
        return addr == ip;
    }
    false
}

fn port_ok(ports: &[String], port: u16) -> bool {
    ports.is_empty() || ports.iter().any(|item| port_item(item, port))
}

fn port_item(item: &str, port: u16) -> bool {
    if let Some((start, end)) = item.split_once('-') {
        let Ok(start) = start.parse::<u16>() else {
            return false;
        };
        let Ok(end) = end.parse::<u16>() else {
            return false;
        };
        return port >= start && port <= end;
    }
    item.parse::<u16>().ok() == Some(port)
}

fn proto_ok(protocol: &[String]) -> bool {
    protocol.is_empty() || protocol.iter().any(|item| item.eq_ignore_ascii_case("tcp"))
}

struct Leaf {
    kind: DecisionKind,
    node: String,
}

fn resolve(loaded: &Loaded, target: &str, depth: u8) -> Option<Leaf> {
    if depth > 8 {
        return Some(Leaf {
            kind: DecisionKind::Block,
            node: "block".to_string(),
        });
    }
    match target {
        "direct" => Some(Leaf {
            kind: DecisionKind::Direct,
            node: "direct".to_string(),
        }),
        "block" => Some(Leaf {
            kind: DecisionKind::Block,
            node: "block".to_string(),
        }),
        name => {
            if loaded.groups.contains_key(name) {
                let members = loaded.groups.get(name)?;
                let choice = loaded
                    .defaults
                    .get(name)
                    .cloned()
                    .or_else(|| first_name(loaded, members));
                let member = choice
                    .as_deref()
                    .and_then(|choice| find_member(loaded, members, choice))
                    .or_else(|| members.first().cloned());
                return match member? {
                    Member::Direct => Some(Leaf {
                        kind: DecisionKind::Direct,
                        node: "direct".to_string(),
                    }),
                    Member::Block => Some(Leaf {
                        kind: DecisionKind::Block,
                        node: "block".to_string(),
                    }),
                    Member::Pool => {
                        let node = loaded.order.first()?;
                        Some(Leaf {
                            kind: proxy_node(loaded.nodes.get(node)?),
                            node: node.clone(),
                        })
                    }
                    Member::Name(member) => resolve(loaded, &member, depth + 1),
                };
            }
            loaded.nodes.get(name).map(|node| Leaf {
                kind: proxy_node(node),
                node: name.to_string(),
            })
        }
    }
}

fn first_name(loaded: &Loaded, members: &[Member]) -> Option<String> {
    members.iter().find_map(|member| match member {
        Member::Direct => Some("direct".to_string()),
        Member::Block => Some("block".to_string()),
        Member::Name(name) => Some(name.clone()),
        Member::Pool => loaded.order.first().cloned(),
    })
}

fn find_member(loaded: &Loaded, members: &[Member], choice: &str) -> Option<Member> {
    if choice == "direct"
        && members
            .iter()
            .any(|member| matches!(member, Member::Direct))
    {
        return Some(Member::Direct);
    }
    if choice == "block" && members.iter().any(|member| matches!(member, Member::Block)) {
        return Some(Member::Block);
    }
    if members
        .iter()
        .any(|member| matches!(member, Member::Name(name) if name == choice))
        || (loaded.nodes.contains_key(choice)
            && members.iter().any(|member| matches!(member, Member::Pool)))
        || loaded.groups.contains_key(choice)
            && members
                .iter()
                .any(|member| matches!(member, Member::Name(name) if name == choice))
    {
        return Some(Member::Name(choice.to_string()));
    }
    None
}

fn proxy_node(node: &Node) -> DecisionKind {
    if !ss::supported_method(&node.method) {
        return DecisionKind::Block;
    }
    DecisionKind::Proxy {
        server_host: node.host.clone(),
        server_port: node.port,
        password: node.password.clone(),
    }
}

pub async fn handle(
    path: &Path,
    cache: Option<&Path>,
    selections: &Path,
    stream: tokio::net::TcpStream,
    dest: SocketAddr,
    src: SocketAddr,
    prelude: Vec<u8>,
) -> std::io::Result<()> {
    let sniffed = crate::sniff::sniff_parts(&prelude);
    let domain = sniffed.domain();
    let decision = decide(
        path,
        cache,
        selections,
        &Query {
            domain: domain.clone(),
            dest,
            src,
        },
        sniffed.sni.as_deref().unwrap_or(""),
        sniffed.host.as_deref().unwrap_or(""),
    )
    .map_err(|error| std::io::Error::other(error.to_string()))?;
    eprintln!("honk-dataplane: {}", decision.log_line());
    match decision.kind {
        DecisionKind::Block => Ok(()),
        DecisionKind::Direct => direct_with_prelude(stream, dest, &prelude).await,
        DecisionKind::Proxy {
            server_host,
            server_port,
            password,
        } => {
            let host = domain.unwrap_or_else(|| dest.ip().to_string());
            crate::dial_honk_outbound(
                &server_host,
                server_port,
                &password,
                &host,
                dest.port(),
                stream,
                &prelude,
            )
            .await
        }
    }
}

async fn direct_with_prelude(
    mut client: tokio::net::TcpStream,
    dest: SocketAddr,
    prelude: &[u8],
) -> std::io::Result<()> {
    let mut upstream = tokio::net::TcpStream::connect(dest).await?;
    if !prelude.is_empty() {
        tokio::io::AsyncWriteExt::write_all(&mut upstream, prelude).await?;
    }
    let _ = tokio::io::copy_bidirectional(&mut client, &mut upstream).await?;
    Ok(())
}

pub fn ui_rows(path: &Path, cache: Option<&Path>, selections: &Path) -> anyhow::Result<String> {
    reload(path, cache, selections)?;
    let guard = LOADED.lock().expect("route lock");
    let loaded = &guard.as_ref().expect("loaded").1;
    let mut html = String::new();
    let mut names: Vec<_> = loaded.groups.keys().cloned().collect();
    names.sort();
    for name in names {
        let members = &loaded.groups[&name];
        let current = loaded.defaults.get(&name).cloned().unwrap_or_default();
        html.push_str("<tr><th width=\"40%\">");
        html.push_str(&escape(&name));
        html.push_str("</th><td><select class=\"input_option\" id=\"honk_sel_");
        html.push_str(&escape(&name));
        html.push_str("\">");
        for label in choice_labels(loaded, members) {
            let selected = if label == current { " selected" } else { "" };
            html.push_str("<option value=\"");
            html.push_str(&escape(&label));
            html.push('"');
            html.push_str(selected);
            html.push('>');
            html.push_str(&escape(&label));
            html.push_str("</option>");
        }
        html.push_str("</select></td></tr>\n");
    }
    Ok(html)
}

fn choice_labels(loaded: &Loaded, members: &[Member]) -> Vec<String> {
    let mut labels = Vec::new();
    for member in members {
        match member {
            Member::Direct => labels.push("direct".to_string()),
            Member::Block => labels.push("block".to_string()),
            Member::Name(name) => labels.push(name.clone()),
            Member::Pool => labels.extend(loaded.order.iter().cloned()),
        }
    }
    labels
}

fn escape(text: &str) -> String {
    text.replace('&', "&amp;")
        .replace('<', "&lt;")
        .replace('>', "&gt;")
        .replace('"', "&quot;")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn suffix_and_cidr_keep_source_order() {
        let text = r#"
routing {
    domain(suffix: 'example.com') -> Netflix
    dip(198.51.100.0/24) -> direct
    fallback: Proxies
}
group {
    Netflix {
        filter: name(direct)
        policy: select
        default: direct
    }
    Proxies {
        filter: name('Alpha')
        policy: select
        default: 'Alpha'
    }
}
node {
    'Alpha': 'ss://Y2hhY2hhMjAtaWV0Zi1wb2x5MTMwNTpmYWtl@203.0.113.20:8388'
}
"#;
        let config = parse_dae_config(text).unwrap();
        let loaded = Loaded {
            rules: config.routing.rules,
            fallback: config.routing.default_outbound,
            groups: HashMap::new(),
            defaults: HashMap::new(),
            nodes: HashMap::new(),
            order: Vec::new(),
        };
        let dest = "203.0.113.9:443".parse().unwrap();
        let src = "192.168.50.20:40000".parse().unwrap();
        assert_eq!(
            match_rule(
                &loaded,
                &Query {
                    domain: Some("a.example.com".into()),
                    dest,
                    src
                }
            )
            .0,
            "Netflix"
        );
        assert_eq!(
            match_rule(
                &loaded,
                &Query {
                    domain: None,
                    dest: "198.51.100.9:443".parse().unwrap(),
                    src
                }
            )
            .0,
            "direct"
        );
        assert_eq!(
            match_rule(
                &loaded,
                &Query {
                    domain: None,
                    dest,
                    src
                }
            )
            .0,
            "Proxies"
        );
    }

    #[test]
    fn geoip_does_not_match_without_a_database() {
        let text = "routing {\n    dip(geoip:cn) -> direct\n    fallback: Proxies\n}\n";
        let config = parse_dae_config(text).unwrap();
        let loaded = Loaded {
            rules: config.routing.rules,
            fallback: config.routing.default_outbound,
            groups: HashMap::new(),
            defaults: HashMap::new(),
            nodes: HashMap::new(),
            order: Vec::new(),
        };
        let query = Query {
            domain: None,
            dest: "1.1.1.1:443".parse().unwrap(),
            src: "192.168.50.2:9".parse().unwrap(),
        };
        assert_eq!(match_rule(&loaded, &query).0, "Proxies");
    }

    #[test]
    fn decision_names_the_sni_rule_group_and_node() {
        let text = r#"
routing {
    domain(suffix: 'example.com') -> Netflix
    fallback: Proxies
}
group {
    Netflix {
        filter: name('Alpha')
        policy: select
        default: 'Alpha'
    }
}
node {
    'Alpha': 'ss://Y2hhY2hhMjAtaWV0Zi1wb2x5MTMwNTpmYWtl@203.0.113.20:8388'
}
"#;
        let loaded =
            super::build_loaded(text, None, std::path::Path::new("/no/such/select.txt")).unwrap();
        let decision = super::explain(
            &loaded,
            &Query {
                domain: Some("a.example.com".into()),
                dest: "203.0.113.9:443".parse().unwrap(),
                src: "192.168.50.20:40000".parse().unwrap(),
            },
            "a.example.com",
            "",
        );
        assert!(matches!(decision.kind, DecisionKind::Proxy { .. }));
        assert_eq!(
            decision.log_line(),
            "decision sni=a.example.com host=- rule=domain(suffix:example.com)->Netflix group=Netflix node=Alpha"
        );
    }

    #[test]
    fn owner_mode_600_config_is_readable() {
        let dir = std::env::temp_dir().join(format!("honk-mode-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("config.dae");
        std::fs::write(&path, "routing {\n fallback: direct\n}\n").unwrap();
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            let mut perms = std::fs::metadata(&path).unwrap().permissions();
            perms.set_mode(0o600);
            std::fs::set_permissions(&path, perms).unwrap();
        }
        let report = load_configured(&path, None, &dir.join("select.txt")).unwrap();
        assert_eq!(report.mode & 0o777, 0o600);
        let line = report.log_line(&path);
        assert!(line.contains("mode=600"), "{line}");
        assert!(line.contains("nodes=0"), "{line}");
        assert!(!report.subscription);
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn a_subscription_without_nodes_is_refused() {
        let dir = std::env::temp_dir().join(format!("honk-sub-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("config.dae");
        std::fs::write(
            &path,
            "subscription {\n airport: 'https://example.test/a'\n}\nrouting {\n fallback: direct\n}\n",
        )
        .unwrap();
        let error = load_configured(&path, None, &dir.join("select.txt")).unwrap_err();
        assert!(
            error.to_string().contains("no shadowsocks nodes"),
            "{error}"
        );
        let cache = dir.join("nodes.cache");
        std::fs::write(
            &cache,
            "Alpha = ss, 203.0.113.20, 8388, encrypt-method=chacha20-ietf-poly1305, password=fake\n",
        )
        .unwrap();
        let report = load_configured(&path, Some(&cache), &dir.join("select.txt")).unwrap();
        assert_eq!(report.nodes, 1);
        assert!(report.subscription);
        let _ = std::fs::remove_dir_all(&dir);
    }
}
