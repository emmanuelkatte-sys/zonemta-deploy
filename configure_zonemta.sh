#!/usr/bin/env bash
# ZonePMTA (ZoneMTA) configure — extract bundled node_modules (no npm on VPS).
# Aligned with Haraka/PMTA SMTP ingest: VERP + strip Received/leak + real DKIM.
echo 'CONFIGURE_FAIL_1' > /tmp/configure.result

if [ "$EUID" -ne 0 ]; then
    echo "ERROR: 请使用 root 权限运行"
    echo 'CONFIGURE_FAIL_43' > /tmp/configure.result
    exit 43
fi

export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a
hostnamectl set-hostname {{FULL_DOMAIN}} 2>/dev/null || true
sed -i 's/^127\.0\.0\.1.*/127.0.0.1 localhost {{FULL_DOMAIN}}\n{{INTERNAL_IP}} {{SUBDOMAIN}} {{FULL_DOMAIN}}/' /etc/hosts
timedatectl set-timezone Asia/Tokyo 2>/dev/null || true

# ===== 防卡死防护 1: 内存 4G Swap 扩容 (彻底防止海量发件时 OOM / 系统卡死) =====
NEED_CREATE_SWAP=1
if [ -f /swapfile ]; then
    CURRENT_SWAP_SIZE=$(stat -c '%s' /swapfile 2>/dev/null || echo 0)
    if [ "$CURRENT_SWAP_SIZE" -ge 4294967296 ]; then
        NEED_CREATE_SWAP=0
    else
        swapoff /swapfile 2>/dev/null || true
        rm -f /swapfile
    fi
fi
if [ "$NEED_CREATE_SWAP" = "1" ]; then
    fallocate -l 4G /swapfile 2>/dev/null || dd if=/dev/zero of=/swapfile bs=1M count=4096 status=none
    chmod 600 /swapfile
    mkswap /swapfile >/dev/null 2>&1
    swapon /swapfile 2>/dev/null || true
    grep -q '/swapfile' /etc/fstab || echo '/swapfile swap swap defaults 0 0' >> /etc/fstab
fi

# ===== 防卡死防护 2: 内核参数与 SSH 防断连接优化 =====
sysctl -w vm.swappiness=10 2>/dev/null || true
echo "vm.swappiness=10" >> /etc/sysctl.d/99-zonemta.conf 2>/dev/null || true

mkdir -p /etc/ssh/sshd_config.d
cat > /etc/ssh/sshd_config.d/99-warship.conf << 'SSHEOF'
MaxStartups 100:30:200
ClientAliveInterval 30
ClientAliveCountMax 5
SSHEOF
systemctl reload sshd 2>/dev/null || systemctl reload ssh 2>/dev/null || true

apt-get update -y
apt-get install -y curl gnupg ca-certificates redis-server

if ! command -v node >/dev/null 2>&1; then
    curl -fsSL https://deb.nodesource.com/setup_20.x | bash -
    apt-get install -y nodejs
fi
if ! command -v node >/dev/null 2>&1; then
    echo "ERROR: node 未安装"
    echo 'CONFIGURE_FAIL_42' > /tmp/configure.result
    exit 42
fi
NODE_BIN="$(command -v node)"

. /etc/os-release 2>/dev/null || true
CODENAME="${VERSION_CODENAME:-jammy}"
if ! command -v mongod >/dev/null 2>&1 && ! systemctl list-unit-files | grep -q '^mongod'; then
    if [ "$CODENAME" = "noble" ]; then
        MONGO_VER="8.0"
    else
        MONGO_VER="7.0"
    fi
    curl -fsSL "https://www.mongodb.org/static/pgp/server-${MONGO_VER}.asc" | gpg --dearmor --yes -o "/usr/share/keyrings/mongodb-server-${MONGO_VER}.gpg"
    echo "deb [ signed-by=/usr/share/keyrings/mongodb-server-${MONGO_VER}.gpg ] https://repo.mongodb.org/apt/ubuntu ${CODENAME}/mongodb-org/${MONGO_VER} multiverse" > "/etc/apt/sources.list.d/mongodb-org-${MONGO_VER}.list"
    apt-get update -y
    apt-get install -y mongodb-org || apt-get install -y mongodb || true
fi

systemctl enable redis-server 2>/dev/null || systemctl enable redis 2>/dev/null || true
systemctl start redis-server 2>/dev/null || systemctl start redis 2>/dev/null || true

# 限制 MongoDB WiredTiger 内存占用为 256MB，防止大量排队邮件把物理内存耗尽
if [ -f /etc/mongod.conf ]; then
    if ! grep -q 'cacheSizeGB' /etc/mongod.conf; then
        cat >> /etc/mongod.conf << 'MONGOEOF'
storage:
  wiredTiger:
    engineConfig:
      cacheSizeGB: 0.25
MONGOEOF
    fi
fi

systemctl enable mongod 2>/dev/null || systemctl enable mongodb 2>/dev/null || true
systemctl restart mongod 2>/dev/null || systemctl restart mongodb 2>/dev/null || true

systemctl stop zonemta 2>/dev/null || true
systemctl stop haraka 2>/dev/null || true
systemctl stop pmta 2>/dev/null || true
systemctl stop pmtahttp 2>/dev/null || true
for svc in postfix sendmail exim4 exim; do
    systemctl stop "$svc" 2>/dev/null || true
    systemctl disable "$svc" 2>/dev/null || true
done
pkill -f 'node haraka.js' 2>/dev/null || true
pkill -f '/opt/zone-mta/index.js' 2>/dev/null || true
sleep 1

BUNDLE_URL='{{BUNDLE_URL}}'
BUNDLE_SHA256='{{BUNDLE_SHA256}}'
BUNDLE_PRELOADED='{{BUNDLE_PRELOADED}}'
APP=/opt/zone-mta
BUNDLE_TAR=/tmp/zonemta-bundle.tar.gz
rm -f "$BUNDLE_TAR"

if [ -n "$BUNDLE_PRELOADED" ] && [ -f "$BUNDLE_PRELOADED" ]; then
    echo "使用已上传 bundle: $BUNDLE_PRELOADED"
    cp "$BUNDLE_PRELOADED" "$BUNDLE_TAR" || {
        echo "ERROR: 复制预上传 bundle 失败"
        echo 'CONFIGURE_FAIL_42' > /tmp/configure.result
        exit 42
    }
else
    DOWNLOAD_OK=0
    for i in 1 2 3; do
        echo "Bundle 下载尝试 $i/3..."
        rm -f "$BUNDLE_TAR"
        if [ -n "$BUNDLE_URL" ] && wget -4 -q -L --timeout=120 --tries=1 -O "$BUNDLE_TAR" "$BUNDLE_URL"; then
            if [ -s "$BUNDLE_TAR" ]; then
                DOWNLOAD_OK=1
                break
            fi
        fi
        echo "第 $i 次下载失败"
        [ $i -lt 3 ] && sleep 3
    done
    if [ "$DOWNLOAD_OK" != "1" ]; then
        echo "ERROR: zonemta bundle 下载失败（且无预上传文件）"
        echo 'CONFIGURE_FAIL_42' > /tmp/configure.result
        exit 42
    fi
fi

ACTUAL_SHA256=$(sha256sum "$BUNDLE_TAR" | awk '{print $1}')
if [ "$ACTUAL_SHA256" != "$BUNDLE_SHA256" ]; then
    echo "ERROR: zonemta bundle sha256 不匹配"
    echo "  期望: $BUNDLE_SHA256"
    echo "  实际: $ACTUAL_SHA256"
    rm -f "$BUNDLE_TAR"
    echo 'CONFIGURE_FAIL_42' > /tmp/configure.result
    exit 42
fi
echo "Bundle sha256 校验通过"

rm -rf "$APP" /tmp/zonemta-bundle /tmp/zonemta-extract
mkdir -p /tmp/zonemta-extract
if ! tar -xzf "$BUNDLE_TAR" -C /tmp/zonemta-extract; then
    echo "ERROR: zonemta bundle 解压失败"
    rm -f "$BUNDLE_TAR"
    echo 'CONFIGURE_FAIL_42' > /tmp/configure.result
    exit 42
fi
rm -f "$BUNDLE_TAR" "$BUNDLE_PRELOADED"
if [ -d /tmp/zonemta-extract/zonemta-bundle ]; then
    mv /tmp/zonemta-extract/zonemta-bundle "$APP"
elif [ -f /tmp/zonemta-extract/index.js ]; then
    mv /tmp/zonemta-extract "$APP"
else
    echo "ERROR: bundle 顶层不是 zonemta-bundle/ 或 index.js"
    ls -la /tmp/zonemta-extract >&2 || true
    echo 'CONFIGURE_FAIL_42' > /tmp/configure.result
    exit 42
fi
rm -rf /tmp/zonemta-extract

if [ ! -f "$APP/index.js" ] || [ ! -d "$APP/node_modules/@zone-eu/zone-mta" ]; then
    echo "ERROR: 缺少 @zone-eu/zone-mta"
    echo 'CONFIGURE_FAIL_42' > /tmp/configure.result
    exit 42
fi

mkdir -p "$APP/plugins" "$APP/plugins/data" "$APP/logs" "$APP/config/plugins" "$APP/config/interfaces" "$APP/config/zones" "$APP/keys"

cat > "$APP/config/zonemta.toml" << 'EOF'
name = ""
ident = "zone-mta"
pluginsPath = "./plugins"
corePluginsPath = "./node_modules/@zone-eu/zone-mta/plugins/"
[log]
level = "info"
[dbs]
mongo = "mongodb://127.0.0.1:27017/zone-mta"
redis = "redis://127.0.0.1:6379/2"
sender = "zone-mta"
[queue]
instanceId = "default"
collection = "zone-queue"
gfs = "mail"
[api]
port = 12080
[smtpInterfaces]
# @include "interfaces/*.toml"
[plugins]
# @include "plugins/*.toml"
[zones]
# @include "zones/*.toml"
EOF

cat > "$APP/config/interfaces/feeder.toml" << 'EOF'
[feeder]
enabled = true
processes = 1
maxSize = 20971520
host = "127.0.0.1"
port = 587
authentication = true
maxRecipients = 1000
starttls = false
secure = false
key = "/opt/zone-mta/keys/privkey.pem"
cert = "/opt/zone-mta/keys/fullchain.pem"
EOF

cat > "$APP/config/zones/default.toml" << 'EOF'
[default]
processes = 1
connections = 5
pool = ""
EOF

cat > "$APP/config/plugins/default-headers.toml" << 'EOF'
["core/default-headers"]
enabled = ["receiver", "main", "sender"]
addMissing = ["message-id", "date"]
futureDate = false
xOriginatingIP = false
EOF

cat > "$APP/config/plugins/log_delivered.toml" << 'EOF'
["log_delivered"]
enabled = ["receiver", "main", "sender"]
selector = "{{DKIM_SELECTOR}}"
domain = "{{FULL_DOMAIN}}"
smtp_user = "{{SUBDOMAIN}}@{{FULL_DOMAIN}}"
email_pass = "{{EMAIL_PASS}}"
EOF

cat > "$APP/config/plugins/pmta_header_align.toml" << 'EOF'
["pmta_header_align"]
enabled = ["receiver", "main", "sender"]
EOF

cat > "$APP/config/plugins/pmta_verp.toml" << 'EOF'
["pmta_verp"]
enabled = ["receiver", "main", "sender"]
EOF

cat > "$APP/config/plugins/pmta_feeder_auth.toml" << EOF
["pmta_feeder_auth"]
enabled = ["receiver"]
interfaces = ["feeder"]
username = "{{SUBDOMAIN}}@{{FULL_DOMAIN}}"
password = "{{EMAIL_PASS}}"
EOF

cat > "$APP/config/plugins/dkim.toml" << EOF
["core/dkim"]
enabled = ["sender"]
domain = "{{FULL_DOMAIN}}"
signTransportDomain = false
selector = "{{DKIM_SELECTOR}}"
path = "/opt/zone-mta/keys/dkim-private.pem"
headerFields = []
additionalHeaderFields = []
addSignatureTimestamp = true
signatureExpireIn = 0
EOF

cat > "$APP/config/plugins/zonemta-limiter.toml" << 'EOF'
["modules/zonemta-limiter"]
enabled = false
EOF

cat > "$APP/config/plugins/avast.toml" << 'EOF'
["modules/zonemta-avast"]
enabled = false
EOF

cat > "$APP/config/plugins/email-bounce.toml" << 'EOF'
["core/email-bounce"]
enabled = false
EOF

cat > "$APP/config/plugins/image-hashes.toml" << 'EOF'
["core/image-hashes"]
enabled = false
EOF

cat > "$APP/plugins/pmta_header_align.js" << 'JSEOF'
'use strict';
module.exports.title = 'PMTA header align';
const STRIP = [
    'x-virtual-mta','x-job','return-path','x-originating-ip',
    'x-php-script','x-php-originating-script','user-agent','x-msmail-priority',
    'x-mimeole','x-sender','x-antiabuse','x-source','x-source-args','x-source-dir',
    'x-haraka','x-haraka-uuid','x-haraka-transaction','x-sending-zone','x-zonemta-queue-id'
];
function stripHeaders(headers) {
    if (!headers || typeof headers.remove !== 'function') return;
    for (const name of STRIP) {
        try { headers.remove(name); } catch (e) {}
    }
}
module.exports.init = (app, done) => {
    app.addHook('message:headers', (envelope, messageInfo, next) => {
        try { stripHeaders(envelope && envelope.headers); } catch (e) {}
        next();
    });
    app.addHook('sender:headers', (delivery, connection, next) => {
        try { stripHeaders(delivery && delivery.headers); } catch (e) {}
        next();
    });
    done();
};
JSEOF

cat > "$APP/plugins/pmta_verp.js" << 'JSEOF'
'use strict';
module.exports.title = 'PMTA VERP';
function encodeRecipient(addr) {
    let out = '';
    for (const ch of String(addr || '')) {
        if (ch === '@') out += '=';
        else if (/[0-9A-Za-z.]/.test(ch)) out += ch;
        else {
            const hex = ch.charCodeAt(0).toString(16).toUpperCase();
            out += '+' + (hex.length < 2 ? '0' + hex : hex);
        }
    }
    return out;
}
function applyVerp(envelope) {
    if (!envelope) return;
    const from = String(envelope.from || '');
    const at = from.lastIndexOf('@');
    if (at <= 0) return;
    const user = from.slice(0, at);
    const host = from.slice(at + 1);
    if (!user || !host || user.includes('=')) return;
    const rcpt = String([].concat(envelope.to || [])[0] || '');
    if (!rcpt || rcpt === '<>') return;
    envelope.from = user + '-' + encodeRecipient(rcpt) + '@' + host;
}
module.exports.init = (app, done) => {
    app.addHook('message:headers', (envelope, messageInfo, next) => {
        try { applyVerp(envelope); } catch (e) {}
        next();
    });
    app.addHook('sender:headers', (delivery, connection, next) => {
        try { if (delivery && delivery.envelope) applyVerp(delivery.envelope); } catch (e) {}
        next();
    });
    done();
};
JSEOF

cat > "$APP/plugins/pmta_feeder_auth.js" << 'JSEOF'
'use strict';
module.exports.title = 'PMTA feeder AUTH';
module.exports.init = (app, done) => {
    const username = String((app.config && app.config.username) || '').trim();
    const password = String((app.config && app.config.password) || '');
    app.addHook('smtp:auth', (auth, session, next) => {
        const interfaces = (app.config && app.config.interfaces) || ['feeder'];
        if (session && session.interface && !interfaces.includes(session.interface)) return next();
        if (username && auth && auth.username === username && auth.password === password) return next();
        const err = new Error('Authentication failed');
        err.responseCode = 535;
        return next(err);
    });
    done();
};
JSEOF

base64 -d > "$APP/plugins/log_delivered.js" << 'EOF'
{{PLUGIN_LOG_DELIVERED_B64}}
EOF

base64 -d > "$APP/keys/fullchain.pem" << 'EOF'
{{TLS_FULLCHAIN_B64}}
EOF
base64 -d > "$APP/keys/privkey.pem" << 'EOF'
{{TLS_PRIVKEY_B64}}
EOF
base64 -d > "$APP/keys/dkim-private.pem" << 'EOF'
{{DKIM_PRIVATE_B64}}
EOF
chmod 600 "$APP/keys/privkey.pem" "$APP/keys/dkim-private.pem"
chmod 644 "$APP/keys/fullchain.pem"

cat > /etc/systemd/system/zonemta.service << EOF
[Unit]
Description=ZonePMTA (ZoneMTA)
After=network.target mongod.service redis-server.service redis.service
Wants=mongod.service redis-server.service

[Service]
Environment=NODE_ENV=production
WorkingDirectory=/opt/zone-mta
ExecStart=${NODE_BIN} --max-old-space-size=2048 index.js --config=/opt/zone-mta/config/zonemta.toml
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

# RFC 8058 / RFC 2369 One-Click Unsubscribe Web Service for ZoneMTA
echo "部署 ZoneMTA RFC 8058 退订服务..."
mkdir -p /opt/zone-mta/unsub/logs
cat > /opt/zone-mta/unsub/unsub_service.js << 'EOFJSUNSUB'
const http = require('http');
const fs = require('fs');
const path = require('path');
const url = require('url');
const querystring = require('querystring');

const LOG_DIR = '/opt/zone-mta/unsub/logs';
const CSV_FILE = path.join(LOG_DIR, 'unsubscribed.csv');

function ensureLog() {
    try {
        if (!fs.existsSync(LOG_DIR)) fs.mkdirSync(LOG_DIR, { recursive: true });
        if (!fs.existsSync(CSV_FILE)) {
            fs.writeFileSync(CSV_FILE, 'TimeISO,Email,IP,Method,UserAgent\n', 'utf8');
        }
    } catch (e) {}
}

function recordUnsub(email, ip, method, ua) {
    if (!email || email.indexOf('@') < 1) return;
    const cleanEmail = String(email).trim().toLowerCase();
    try {
        ensureLog();
        const ts = new Date().toISOString();
        const line = `"${ts}","${cleanEmail.replace(/"/g, '""')}","${ip || ''}","${method || 'GET'}","${(ua || '').replace(/"/g, '""')}"\n`;
        fs.appendFileSync(CSV_FILE, line, 'utf8');
    } catch (e) {}
}

const HTML_TEMPLATE = `<!DOCTYPE html>
<html lang="ja">
<head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>配信停止の手続き完了 - Unsubscribed</title>
    <style>
        body { font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", "Hiragino Kaku Gothic ProN", "Hiragino Sans", "BIZ UDPGothic", Meiryo, sans-serif; background: #0b0f19; color: #f1f5f9; display: flex; align-items: center; justify-content: center; min-height: 100vh; margin: 0; padding: 20px; box-sizing: border-box; }
        .card { background: #161e2e; border: 1px solid #283548; border-radius: 16px; padding: 40px 32px; max-width: 480px; width: 100%; text-align: center; box-shadow: 0 25px 50px -12px rgba(0, 0, 0, 0.6); }
        .icon { width: 64px; height: 64px; background: rgba(34, 197, 94, 0.15); color: #22c55e; border-radius: 50%; display: inline-flex; align-items: center; justify-content: center; font-size: 30px; margin-bottom: 20px; }
        h1 { font-size: 20px; font-weight: 600; margin: 0 0 6px 0; color: #ffffff; letter-spacing: 0.02em; }
        .sub { font-size: 13px; color: #64748b; margin: 0 0 18px 0; font-weight: 500; }
        p { font-size: 14px; color: #94a3b8; line-height: 1.7; margin: 0 0 16px 0; }
        .email-badge { display: inline-block; background: #0f172a; border: 1px solid #334155; color: #38bdf8; padding: 6px 14px; border-radius: 9999px; font-size: 13px; font-family: ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas, monospace; margin-bottom: 18px; word-break: break-all; }
        .note { font-size: 12px; color: #94a3b8; line-height: 1.6; margin-top: 18px; text-align: left; background: rgba(15, 23, 42, 0.6); padding: 12px 14px; border-radius: 8px; border-left: 3px solid #38bdf8; }
        .footer { font-size: 11px; color: #475569; border-top: 1px solid #283548; padding-top: 16px; margin-top: 24px; }
    </style>
</head>
<body>
    <div class="card">
        <div class="icon">&#10003;</div>
        <h1>配信停止の手続きが完了しました</h1>
        <div class="sub">Unsubscription Completed</div>
        <p>お客様のメールアドレスへのご案内メールの配信を停止いたしました。<br>これ以降、本配信リストからのメールは届きません。</p>
        __BADGE__
        <div class="note">※ 反映に数时间程度かかる場合がございます。万が一メールが届いた場合は、お手数ですが再度ご連絡ください。</div>
        <div class="footer">RFC 8058 One-Click List-Unsubscribe Service</div>
    </div>
</body>
</html>`;

const requestHandler = (req, res) => {
    const parsed = url.parse(req.url, true);
    const ip = (req.headers['x-forwarded-for'] || req.socket.remoteAddress || '').split(',')[0].trim();
    const ua = req.headers['user-agent'] || '';

    if (req.method === 'POST') {
        let body = '';
        req.on('data', chunk => { body += chunk; });
        req.on('end', () => {
            const postData = querystring.parse(body);
            const email = parsed.query.email || postData.email || parsed.query.id || '';
            if (email) recordUnsub(email, ip, 'POST', ua);
            res.writeHead(200, { 'Content-Type': 'text/plain; charset=utf-8' });
            res.end('Unsubscribed successfully\r\n');
        });
        return;
    }

    const email = parsed.query.email || parsed.query.addr || parsed.query.id || '';
    if (email) recordUnsub(email, ip, 'GET', ua);
    const badge = email && email.includes('@') ? `<div class="email-badge">${email.replace(/[&<>"']/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]))}</div>` : '';
    const html = HTML_TEMPLATE.replace('__BADGE__', badge);
    const buf = Buffer.from(html, 'utf8');
    res.writeHead(200, {
        'Content-Type': 'text/html; charset=utf-8',
        'Content-Length': buf.length,
        'X-Robots-Tag': 'noindex, nofollow'
    });
    res.end(buf);
};

ensureLog();
try {
    const s9091 = http.createServer(requestHandler);
    s9091.listen(9091, '0.0.0.0');
} catch (e) {}
try {
    const s80 = http.createServer(requestHandler);
    s80.listen(80, '0.0.0.0');
} catch (e) {}
EOFJSUNSUB
chmod 755 /opt/zone-mta/unsub/unsub_service.js

cat > /etc/systemd/system/zonemta-unsub.service << EOF
[Unit]
Description=ZoneMTA RFC 8058 One-Click Unsubscribe Service
After=network.target

[Service]
Type=simple
ExecStart=${NODE_BIN} /opt/zone-mta/unsub/unsub_service.js
Restart=always
RestartSec=3
WorkingDirectory=/opt/zone-mta/unsub

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable zonemta-unsub 2>/dev/null || true
systemctl restart zonemta-unsub 2>/dev/null || true

sleep 2
iptables -A INPUT -p tcp --dport 12080 ! -s 127.0.0.1 -j DROP 2>/dev/null || true
which ufw >/dev/null 2>&1 && ufw deny 12080/tcp 2>/dev/null || true
iptables -I INPUT -p tcp --dport 80 -j ACCEPT 2>/dev/null || true
which ufw >/dev/null 2>&1 && ufw allow 80/tcp 2>/dev/null || true
iptables -I INPUT -p tcp --dport 9091 -j ACCEPT 2>/dev/null || true
which ufw >/dev/null 2>&1 && ufw allow 9091/tcp 2>/dev/null || true
netfilter-persistent save 2>/dev/null || true
systemctl daemon-reload
systemctl enable zonemta
systemctl restart zonemta
sleep 3
if ! systemctl is-active --quiet zonemta; then
    echo "ERROR: zonemta 未能启动"
    journalctl -u zonemta -n 40 --no-pager || true
    echo 'CONFIGURE_FAIL_42' > /tmp/configure.result
    exit 42
fi

echo 'CONFIGURE_OK' > /tmp/configure.result
echo CONFIGURE_OK
