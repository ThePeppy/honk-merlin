# Merlin 上使用的 honk 配置

honk 的配置是 dae 语法，不是 Surge，也不是 Clash YAML。下面只写本仓库解析器真正接受的形式，依据是 `doc/en/configuration.md`、`doc/en/reference/nodes.md`、`doc/en/reference/groups.md`、`doc/en/reference/routing.md` 和 `doc/en/reference/subscription.md`。`merlin/tools/surge2honk.py` 把 Surge 转成这种文件。转换器自己的注释以 `# merlin-` 开头，honk 会把它们当注释丢掉；Merlin 插件用它们记录成员顺序和订阅过滤。

## 文件外形

段的顺序没有要求。标量用 `键: 值`。`#` 在空白之后才是注释。含空格、`:`、`#` 的值要加引号。组最多 250 个。

```dae
global {
    lan_interface: br0
    wan_interface: auto
    log_level: info
    dial_mode: domain
    bootstrap_resolver: '1.1.1.1:53'
    store_subscribe: true
}

node {
    edge: 'ss://BASE64@203.0.113.10:8388'
}

subscription {
    airport: 'https://example.example/sub' {
        interval: 86400s
        route: direct
    }
}

group {
    Proxies {
        filter: subtag('airport')
        policy: select
    }
}

routing {
    dip(192.168.0.0/16) -> direct(must)
    domain(suffix: 'example.com') -> Proxies
    fallback: Proxies
}
```

`dial_mode: domain` 在完整 honk 里表示先嗅探域名，再核对目的 IP。Merlin 这一阶段只做嗅探，不加载 geosite/geoip 数据库，见文末。

## 节点

`node` 的每一行是一条分享链接。显式标签会覆盖链接里的名字：

```dae
node {
    '香港 01': 'ss://YWVzLTI1Ni1nY206cGFzcw@203.0.113.10:8388'
}
```

Shadowsocks 用 `ss://`。SIP002 是 `ss://base64(method:password)@主机:端口`。也接受旧式 `ss://base64(method:password@主机:端口)`。AEAD 方法在 honk 里包括 `aes-128-gcm`、`aes-256-gcm`、`chacha20-ietf-poly1305`（别名 `chacha20-poly1305`）。Merlin 插件这一阶段只拨 `chacha20-ietf-poly1305`。

节点不能直接写在路由规则的目标上。`Config::validate` 会拒绝裸节点名。目标只能是 `direct`、`block` 或组名。

## 订阅

```dae
subscription {
    airport: 'https://example.example/list' {
        interval: 86400s
        route: direct
        ua: 'honk/0'
        cache: true
    }
}
```

| 键 | 含义 |
| --- | --- |
| 标签 | `subtag('airport')` 用的名字。不写标签时用 URL 的主机名 |
| `interval` | 刷新间隔，单位秒，写成 `86400s`。`0` 表示不周期刷新。默认 `86400s` |
| `route` | `direct` 表示下载不走路由。`routing` 表示按规则走。组名表示固定走那个组 |
| `ua` | 覆盖 User-Agent。默认 `honk/<版本>` |
| `cache` | 是否把正文放进状态库。默认开 |

`sub_type` 固定是 `simple`。正文可以是分享链接列表，也可以是 Surge/Surfboard/Loon 的逗号记录（`[Proxy]` 段；其它段会被忽略）。刷新后的节点带订阅 ID，组里的 `subtag(...)` 会重新匹配。

Surge 的 `policy-regex-filter` 不是 honk 的字段。转换器把它写成：

```dae
# merlin-policy-regex:^(?!.*(剩余流量|距离下次|套餐到期)).*$
```

Mac 上的转换器按这条正则丢掉信息节点。路由器上的 `import-surge` 只识别这种「负向前瞻里是若干字面量」的写法，效果是名字里含这些词的行不导入。

## 组

```dae
group {
    Proxies {
        filter: subtag('airport')
        policy: select
        default: '节点甲'
    }
    Netflix {
        filter: group(Proxies)
        filter: name(direct)
        policy: select
        default: Proxies
    }
}
```

| 键 | 含义 |
| --- | --- |
| 段名 | 路由和 API 里的组名 |
| `policy` | 不写就是 `selector`。`select`、`selector`、`fixed`、`fixed(0)` 都是手动选择 |
| `filter` | 多行是「或」。一行里的 `&&` 是「与」，`!` 只否定紧跟着的那个谓词 |
| `filter: name(...)` | 按节点名。精确、`keyword:`、`regex:`。多个参数是「或」。大小写敏感 |
| `filter: name(direct)` | 唯一能把内置 `direct` 放进组的写法 |
| `filter: subtag('标签')` | 选这个订阅当前的节点 |
| `filter: group(名字)` | 嵌套组。解析后记在 `groups`，不是节点过滤 |
| `default` | `selector` 没有运行时选择时用的成员名。可以是节点、嵌套组或 `direct` |
| `final` | 策略没有可选成员时的显式出口：`direct`、`block`、组或节点。不会偷偷变成 direct |

没有过滤、也没有嵌套组时，组会包含全部节点。只要写了过滤或嵌套组，就不会自动包含全部节点。

选择顺序是：这个网络上已经记下的选择，然后 `default`，然后第一个还在的成员。健康检查不会把 `selector` 换成另一个成员。

转换器额外写：

```dae
# merlin-members:Netflix=Proxies|direct|@airport
```

`@标签` 表示按缓存顺序展开那个订阅的节点。`|` 分隔成员。这只给 Merlin 插件用来保持 Surge 里的顺序；honk 本体不读它。`default` 仍然是 honk 的字段，转换器把它设成 Surge 的第一个成员（订阅节点还没拉下来时，第一个成员如果是订阅本身，就先不写 `default`，运行时用缓存里的第一个节点）。

## 规则

```dae
routing {
    domain(full: 'www.example.com') -> Netflix
    domain(suffix: 'example.com') -> Google
    domain(keyword: 'cdn') -> Proxies
    dip(1.2.3.0/24) -> direct
    dip('2001:db8::/32') -> direct
    dip(geoip:cn) -> direct
    domain(geosite: geolocation-cn) -> direct
    fallback: Proxies
}
```

规则按源码顺序，优先级从 0 递增。`fallback:` 是都不中时的目标，别名是 `default:`。不写 fallback 时 honk 用 `direct`。

| 匹配 | 写法 |
| --- | --- |
| 完整域名 | `domain(full: '名字')` |
| 后缀 | `domain(suffix: 'example.com')`，也中 `a.example.com` |
| 关键字 | `domain(keyword: '片段')` |
| 正则 | `domain(regex: '^a')` |
| geosite | `domain(geosite: 代码)` |
| 目的 CIDR | `dip(1.2.3.0/24)`。含 `:` 的值要加引号 |
| GeoIP | `dip(geoip:cn)`、`dip(geoip:private)` |
| 目的端口 | `dport(80, 443)` 或 `dport(1000-2000)` |
| 协议 | `l4proto(tcp)` |

同一对括号里的逗号是「或」。`&&` 是「与」。目标：

| 目标 | 含义 |
| --- | --- |
| `direct` | 直连 |
| `block` | 丢弃 |
| 组名 | 按那个组的策略选一个成员 |

`(must)` 表示命中后不再嗅探，Clash 的全局模式也不能改写它。`direct(must)` 和 `block` 都是终局。

裸节点名不能当目标。

## Surge 怎么落进这些字段

| Surge | honk |
| --- | --- |
| `[Proxy]` 里的 `ss, 主机, 端口, encrypt-method=..., password=...` | `node` 里的 `ss://` |
| 组行末的 `policy-path=` | `subscription`，`interval` 来自 `update-interval`，`route: direct` |
| `select` 组 | `policy: select`，`default` 为第一个成员 |
| `DIRECT` | `direct`，或 `filter: name(direct)` |
| `REJECT` | `block` |
| `DOMAIN` | `domain(full: ...)` |
| `DOMAIN-SUFFIX` | `domain(suffix: ...)` |
| `DOMAIN-KEYWORD` | `domain(keyword: ...)` |
| `IP-CIDR` / `IP-CIDR6` | `dip(...)`。`no-resolve` 不再单独成字段，因为规则本身不触发 DNS |
| `GEOIP` | `dip(geoip:...)` |
| `FINAL` | `fallback:` |
| `PROCESS-NAME`、`USER-AGENT`、`URL-REGEX` 以及其它不认识的类型 | 丢掉，并在摘要里计数 |

## 面板

在现有 `config.dae` 末尾加上（密钥留空时，局域网里的人可以调用这个 API）：

```dae
experimental {
    clash_api {
        external_controller: '192.168.2.1:9090'
        external_ui: '/jffs/addons/honk/ui'
    }
}
```

面板地址是 `http://192.168.2.1:9090/ui/`。安装包里已经放好 zashboard，所以不必再从 GitHub 下载。策略组在面板里选。

## Merlin 插件这一阶段不做什么

- UDP 不进 REDIRECT。`firewall-start` 在 FORWARD 拒绝局域网 UDP/443，让 QUIC 回落到被 REDIRECT 的 TCP；其它 UDP 直接出去。发往路由器的 TCP 53 也会在 REDIRECT 之前 RETURN。`merlin/scripts/dnsmasq.postconf` 只是路由器上现有的文件，把 dnsmasq 上游指到 `127.0.0.1#5354`。5353 是 avahi 的 mDNS，honk 绑不上。`config.dae` 里要写 `dns.bind: '127.0.0.1:5354'`。`honk_install` 不会把 postconf 拷到 `/jffs/scripts`。
- 安装包带有 `geoip.dat` 和 `geosite.dat`。启动时 `DAE_LOCATION_ASSET` 指向 `/jffs/addons/honk`，`dip(geoip:...)` 和 `domain(geosite:...)` 可以离线命中。
- 发往 `10.0.0.0/8`、`172.16.0.0/12`、`192.168.0.0/16`、`100.64.0.0/10` 以及路由器自己地址的 TCP，在进入 honk 之前就 RETURN。
- 没有 `config.dae` 时不会启用。订阅由 honk-core 自己拉取，使用它的默认 User-Agent，内容是 base64 的 `ss://` 列表。
- 启用期间会 `fc disable` 并 `fc flush`（有 `runner` 时同样 disable），停用时恢复启用前的状态。
