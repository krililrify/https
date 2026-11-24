# Root IP HTTPS

**Root IP HTTPS** 是一个适用于 Ubuntu VPS 的公网 IPv4 HTTPS 证书一键部署工具。

通过 Let's Encrypt 免费申请可信任的公网 IP TLS 证书，自动安装 Nginx、Certbot 并配置证书自动续签。

**无需域名、无需手动申请证书、无需手动搭建 HTTPS 基础环境。**

本项目只负责 HTTPS 基础环境，不会自动生成或覆盖业务反向代理配置。安装完成后，你只需要自行配置 `/etc/nginx/conf.d/site1.conf`。

## 项目特性

- 支持 Ubuntu 22.04 / 24.04 LTS
- 自动识别服务器公网 IPv4
- 支持手动指定公网 IP
- 自动安装 Nginx
- 自动安装新版 Certbot
- 免费申请 Let's Encrypt 公网 IP HTTPS 证书
- 无需域名或 DNS 配置
- 使用 HTTP-01 进行证书验证
- 自动配置证书续签任务
- 证书续签成功后自动重载 Nginx
- 支持重复执行，避免不必要的重复签发
- 不覆盖已有业务 Nginx 配置
- 提供完整的 HTTPS 反代配置模板

> **注意：** Let's Encrypt 短期 IP 证书有效期约为 6 天，需要持续运行自动续签任务。本项目适合全新 Ubuntu VPS，生产环境安装前建议先创建快照备份。

## 一、快速开始

### 1. 克隆 GitHub 仓库

```bash
git clone https://github.com/krililrify/https.git
```

### 2. 进入项目目录

```bash
cd https
```

### 3. 执行一键安装

```bash
sudo bash install.sh
```

脚本将自动检测服务器系统、获取公网 IP、安装基础依赖，并申请正式 HTTPS 证书。

正常情况下，不需要填写任何变量。

## 二、手动指定 IP

默认通过以下接口获取公网 IPv4：

```text
https://api.ipify.org
```

如果 VPS 有多个公网 IP，或者通过 NAT 出网，建议手动指定需要签发证书的 IP。

```bash
sudo env PUBLIC_IP=154.88.64.196 bash install.sh
```

请替换为你的真实公网 IP。

如果希望提供 Let's Encrypt 联系邮箱：

```bash
sudo env \
  PUBLIC_IP=154.88.64.196 \
  LE_EMAIL=you@example.com \
  bash install.sh
```

邮箱是可选项。

## 三、自动安装内容

执行 `install.sh` 后，脚本将依次完成以下操作。

| 步骤 | 自动执行内容 |
|---|---|
| 1 | 检查 root 权限和 Ubuntu 系统版本 |
| 2 | 安装基础系统依赖 |
| 3 | 自动获取并验证公网 IPv4 |
| 4 | 检查 TCP 80 端口是否被占用 |
| 5 | 安装 Snap 和新版 Certbot |
| 6 | 申请 Let's Encrypt 正式 IP 证书 |
| 7 | 安装并启动 Nginx |
| 8 | 处理新安装 Nginx 的默认站点 |
| 9 | 创建证书续签后的 Nginx 重载脚本 |
| 10 | 启用并检查 Certbot 自动续签定时器 |
| 11 | 显示证书路径、签发机构和有效期 |

安装过程不会自动创建 HTTPS 业务站点，也不会修改上游 API 配置。

如果检测到 TCP 80 已被其他程序占用，脚本会安全退出，不会擅自停止已有服务。

## 四、环境要求

| 项目 | 要求 |
|---|---|
| 操作系统 | Ubuntu 22.04 / 24.04 LTS |
| 执行权限 | root 或 sudo |
| IP 地址 | 有效公网 IPv4 |
| TCP 80 | 必须可以从公网访问 |
| HTTPS 端口 | 自行配置，例如 18484 |
| 域名 | 不需要 |
| Nginx | 自动安装 |
| Certbot | 自动安装 |
| 证书费用 | 免费 |

需要确保 VPS 服务商安全组放行 TCP 80，以及你计划使用的 HTTPS 业务端口。

本脚本不会自动调整服务器安全组或 UFW 防火墙规则。

## 五、证书存储位置

假设你的公网 IP 为 `154.88.64.196`。

证书文件：

```text
/etc/letsencrypt/live/154.88.64.196/fullchain.pem
```

私钥文件：

```text
/etc/letsencrypt/live/154.88.64.196/privkey.pem
```

查看证书信息：

```bash
sudo certbot certificates
```

查看证书签发机构、有效期和 IP 地址：

```bash
sudo openssl x509 \
  -in /etc/letsencrypt/live/154.88.64.196/fullchain.pem \
  -noout -issuer -dates -ext subjectAltName
```

证书的 `subjectAltName` 应当包含申请的 IP 地址，并且签发机构应当是正式 Let's Encrypt 证书链，而不是 Staging 测试证书。

## 六、自行配置 Nginx HTTPS 反代

证书安装完成后，只需要自行维护：

```text
/etc/nginx/conf.d/site1.conf
```

仓库提供以下示例文件：

```text
examples/site1.conf.example
```

需要替换三个变量：

| 变量 | 说明 | 示例 |
|---|---|---|
| `__PUBLIC_IP__` | VPS 公网 IPv4 | `154.88.64.196` |
| `__UPSTREAM_HOST__` | HTTPS 反代目标域名 | `example.com` |
| `__PREFIX__` | 允许访问的路径前缀 | `your-secret-path` |

### Nginx 配置示例

以下配置仅作为演示，请替换实际 IP、域名和访问路径。

```nginx
server {
    listen 18484 ssl;
    server_name 154.88.64.196;

    # Let's Encrypt IP HTTPS 证书
    ssl_certificate /etc/letsencrypt/live/154.88.64.196/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/154.88.64.196/privkey.pem;

    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_session_cache shared:SSL:10m;
    ssl_session_timeout 10m;

    # 默认禁止其他路径
    location / {
        return 404;
    }

    # 允许访问基础路径
    location = /your-secret-path {
        proxy_pass https://example.com;

        proxy_ssl_server_name on;
        proxy_ssl_name example.com;
        proxy_ssl_verify on;
        proxy_ssl_trusted_certificate /etc/ssl/certs/ca-certificates.crt;
        proxy_ssl_verify_depth 5;

        proxy_set_header Host example.com;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    }

    # 允许访问该路径下的子路径
    location ^~ /your-secret-path/ {
        proxy_pass https://example.com;

        proxy_ssl_server_name on;
        proxy_ssl_name example.com;
        proxy_ssl_verify on;
        proxy_ssl_trusted_certificate /etc/ssl/certs/ca-certificates.crt;
        proxy_ssl_verify_depth 5;

        proxy_set_header Host example.com;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;

        proxy_connect_timeout 10s;
        proxy_read_timeout 30s;
        proxy_send_timeout 30s;
    }
}
```

`proxy_pass` 不附加 URI 路径，可以保留原请求路径及查询参数。

上游启用 SNI 和 HTTPS 证书验证。

### 保存配置

```bash
sudo nano /etc/nginx/conf.d/site1.conf
```

### 检查 Nginx

```bash
sudo nginx -t
```

### 重新加载配置

```bash
sudo systemctl reload nginx
```

也可以使用：

```bash
sudo nginx -t && sudo systemctl reload nginx
```

### HTTPS 访问示例

```text
https://154.88.64.196:18484/your-secret-path
```

指定路径及其子路径允许访问，其他路径返回 404。

## 七、HTTPS 验证

安装完成并配置 Nginx 后，可以使用 curl 检查 HTTPS 是否正常。

```bash
curl -v https://154.88.64.196:18484/your-secret-path
```

重点查看：

```text
SSL certificate verify ok.
```

以及：

```text
subjectAltName: host "154.88.64.196" matched cert's IP address
```

这些信息表示证书可信且 IP 匹配。

**不要使用 `curl -k` 验证正式证书**，因为该参数会跳过证书校验。

如果上游使用 User-Agent 白名单，可以通过以下方式测试：

```bash
curl -i \
  -A 'YourClient/1.0' \
  'https://154.88.64.196:18484/your-secret-path'
```

如果返回 `403 unknown_user_agent`，可能是上游业务的客户端识别机制拒绝请求，不代表 HTTPS 配置失败。

## 八、证书自动续签

Let's Encrypt 短期 IP 证书约 6 天有效。

本项目使用 Certbot 的自动续签机制，无需手动每隔 6 天重新申请。

### 1. 查看定时器

```bash
sudo systemctl status snap.certbot.renew.timer --no-pager
```

也可以执行：

```bash
sudo systemctl list-timers --all | grep certbot
```

### 2. 模拟续签

```bash
sudo certbot renew --dry-run
```

如果成功，将看到类似：

```text
Congratulations, all simulated renewals succeeded
```

### 3. 验证 Nginx 重载钩子

```bash
sudo certbot renew --dry-run --run-deploy-hooks
```

该命令可进一步验证模拟续签及部署钩子流程。

### 4. 自动重载 Nginx

本项目会创建：

```text
/etc/letsencrypt/renewal-hooks/deploy/kri-ip-https-reload-nginx.sh
```

内容如下：

```bash
#!/bin/sh
set -e

/usr/sbin/nginx -t
/bin/systemctl reload nginx
```

证书成功续签后，Certbot 将执行该部署钩子，检查 Nginx 配置并重新加载。

**注意：** 本项目使用 `standalone` HTTP-01 验证，因此后续自动续签仍需要公网 TCP 80 可访问，且续签时没有其他进程占用该端口。

模拟续签成功不代表未来不会失败，建议持续监控证书到期时间。

## 九、常用维护命令

### 查看 Nginx 状态

```bash
systemctl status nginx --no-pager
```

### 查看 Nginx 版本

```bash
nginx -v
```

### 检查配置

```bash
nginx -t
```

### 重载 Nginx

```bash
systemctl reload nginx
```

### 查看监听端口

```bash
ss -lntp
```

### 查看证书

```bash
certbot certificates
```

### 测试续签

```bash
certbot renew --dry-run
```

### 查看 Nginx 错误日志

```bash
tail -n 50 /var/log/nginx/error.log
```

### 查看 Certbot 日志

```bash
tail -n 50 /var/log/letsencrypt/letsencrypt.log
```

## 十、常见问题

### 1. Connection refused

表示目标 IP 和端口连接被拒绝。

常见原因：

- Nginx 没有启动
- 配置修改后没有重新加载
- 没有监听指定 HTTPS 端口
- 系统防火墙或服务商安全组配置不正确

检查：

```bash
nginx -t
systemctl reload nginx
ss -lntp | grep 18484
```

### 2. Could not bind TCP port 80

表示 TCP 80 已被其他服务占用。

检查：

```bash
ss -lntp | grep ':80 '
```

本项目采用 standalone 模式，要求 Certbot 进行验证时可以独占 TCP 80。

### 3. HTTPS 返回 404

如果配置：

```nginx
location = /prefix
```

只能匹配完整的 `/prefix`。

如果需要允许子路径，应当添加：

```nginx
location ^~ /prefix/
```

### 4. HTTPS 返回 403

如果响应包含：

```text
ClientDistribution: unknown_user_agent
```

说明上游可能存在 User-Agent 白名单。

可以用业务客户端的真实 UA 测试，比较上游直连与反代的响应。

### 5. HTTPS 返回 502

可能原因包括：

- 上游 HTTPS 证书验证失败
- 上游域名解析失败
- SNI 配置错误
- 上游服务器无法连接
- 上游响应超时

检查：

```bash
tail -n 50 /var/log/nginx/error.log
```

### 6. 已有证书，脚本是否重复申请？

本项目会检查同名证书的续签配置。

如果已有证书，默认跳过重复签发，避免不必要地触发证书机构的速率限制。

若现有证书是 Staging 测试证书，或者证书续签配置损坏，需要人工处理。

### 7. 是否可以同时配置多个 HTTPS 反代？

可以。

安装证书后，你可以自行创建多个 Nginx 配置文件。

例如：

```text
/etc/nginx/conf.d/site1.conf
/etc/nginx/conf.d/site2.conf
/etc/nginx/conf.d/site3.conf
```

只要监听端口、server 配置和证书设置合理，就可以共用同一公网 IP 证书。

### 8. 是否可以使用其他 HTTPS 端口？

可以。

例如：

```nginx
listen 18484 ssl;
```

也可以调整为：

```nginx
listen 28484 ssl;
```

证书本身不绑定特定端口。

但需要保证服务商安全组和系统防火墙放行对应 TCP 端口。

### 9. 更换 VPS IP 后怎么办？

在新 VPS 上重新执行安装脚本，自动识别或指定新的公网 IP，并申请对应的 IP 证书。

证书不能直接用于另一个不在证书 SAN 中的 IP 地址。

## 十一、安全说明

- 脚本需要 root 权限，请审阅源码后执行。
- 不建议直接通过不可信来源执行 `curl | bash`。
- 私钥文件不得上传至 GitHub 或其他公开仓库。
- Nginx 反代服务器会终止客户端 TLS，因此服务器本身可以读取请求和响应内容。
- HTTPS 可以保护传输数据，但不能代替接口鉴权。
- 随机访问路径不是可靠的身份认证机制。
- 正式业务部署前应检查 Nginx 配置、证书有效期及自动续签状态。
- 本脚本主要面向全新 VPS，不负责复杂现有网站的迁移。
- 重复运行不会覆盖已有的业务 Nginx 配置文件。

## 十二、项目结构

```text
https/
├── install.sh
├── README.md
├── .gitignore
└── examples/
    └── site1.conf.example
```

其中：

- `install.sh`：自动部署脚本
- `README.md`：安装使用文档
- `.gitignore`：Git 忽略规则
- `examples/site1.conf.example`：HTTPS 反代模板

## 参考资料

- [Let's Encrypt 官方网站](https://letsencrypt.org/)
- [Let's Encrypt 短期及 IP 证书公告](https://letsencrypt.org/2026/03/11/shorter-certs-certbot/)
- [Certbot 官方文档](https://eff-certbot.readthedocs.io/en/stable/using.html)
- [Nginx 官方文档](https://nginx.org/en/docs/)

---

**Root IP HTTPS**

无需域名，为公网 IPv4 快速部署可信任的 HTTPS 服务。

GitHub：https://github.com/krililrify/https
