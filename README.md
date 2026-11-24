# KRI IP HTTPS

在 **Ubuntu 22.04 / 24.04 LTS** 的新 VPS 上，一键安装 Nginx 与 Certbot，免费签发 **Let's Encrypt 公网 IPv4 HTTPS 证书**，配置自动续签。**不会生成或覆盖 `/etc/nginx/conf.d/site1.conf`**，业务反代由你自己配置。

> 适用于已经拥有公网 IPv4，且可以从公网访问 TCP 80 的服务器。证书约 6 天有效，需保持定时续签正常。不要在复杂生产环境直接运行未审计的脚本；建议先快照备份。

## 快速开始

```bash
git clone https://github.com/<你的用户名>/kri-ip-https.git
cd kri-ip-https
sudo bash install.sh
```

脚本默认通过 `https://api.ipify.org` 查询公网 IPv4。若服务器有多个地址、NAT，或查询不正确，请手动指定：

```bash
sudo env PUBLIC_IP=154.88.64.196 bash install.sh
```

如果要给 Let's Encrypt 注册邮箱：

```bash
sudo env PUBLIC_IP=154.88.64.196 LE_EMAIL=you@example.com bash install.sh
```

## 自动完成

- 验证 Ubuntu 版本和 root 权限；安装基础依赖。
- 查询并验证公网 IPv4；检查 TCP 80 是否被占用。
- 通过 Snap 安装新版 Certbot（支持 IP 地址证书）。
- 使用 `standalone` HTTP-01 申请**正式证书**（不使用 Staging）；已有同名证书时跳过重复申请。
- 安装 Nginx；若是本脚本首次安装 Nginx，仅移除 Ubuntu 提供的默认站点软链接，以便 TCP 80 保留给续签。
- 安装 Certbot deploy hook：成功续签后 `nginx -t` 并重载。
- 检查 Certbot 定时器、证书路径及有效期。

**不会自动生成反代业务文件，不会开放系统防火墙端口，不会自动修改你的上游 API。** 已有 TCP 80 服务时脚本安全退出，不自动停止服务。已有更复杂的网站/防火墙环境应人工检查。

## 你需要配置的变量

| 名称 | 是否必填 | 用途 |
|---|---|---|
| `PUBLIC_IP` | 否 | 默认自动查询，可手动指定真实公网 IPv4 |
| `LE_EMAIL` | 否 | Let's Encrypt 账户联系邮箱；省略则不注册邮箱 |
| 反代端口 | 不需要在脚本填写 | 自行编写 `site1.conf`，例如 `18484` |
| 上游域名/路径 | 不需要在脚本填写 | 自行编写 `site1.conf` |

## 自行创建 HTTPS 反代

编辑 `examples/site1.conf.example`，把 `__PUBLIC_IP__`、`__UPSTREAM_HOST__` 和 `__PREFIX__` 换成真实值，再保存为：

```bash
sudo nano /etc/nginx/conf.d/site1.conf
sudo nginx -t && sudo systemctl reload nginx
```

证书位置：

```text
/etc/letsencrypt/live/<公网IP>/fullchain.pem
/etc/letsencrypt/live/<公网IP>/privkey.pem
```

示例允许 `/<前缀>` 和 `/<前缀>/任意子路径`，其他路径返回 404。`proxy_pass https://UPSTREAM_HOST;` **不附加 URI**，可以保留原请求路径。上游启用 SNI 与证书校验。若上游有 UA 白名单，可能返回 `403 unknown_user_agent`，那是业务拒绝，不等于证书失败。

## 验证与维护

```bash
sudo nginx -t
sudo systemctl reload nginx
sudo certbot certificates
sudo systemctl status snap.certbot.renew.timer --no-pager
sudo certbot renew --dry-run --run-deploy-hooks
```

注意，`--dry-run` 成功是模拟续签成功，仍须持续监控正式续签和真实端点证书到期时间。

```bash
curl -v https://<公网IP>:18484/<你的路径>
```

**不要在验证正式证书时使用 `curl -k`**，否则会绕过证书校验。

## 常见故障

- **Connection refused**：配置写完后未 `reload nginx`，或 Nginx 未监听、服务商防火墙未放行。
- **Could not bind TCP port 80**：存在 Nginx 默认站点或其他进程监听 80；检查 `ss -lntp | grep ':80 '`。
- **404**：`location = /prefix` 只能匹配精确路径；含子路径的接口需要 `location ^~ /prefix/`。
- **403 unknown_user_agent**：上游 API 根据客户端 UA 拒绝了 curl；用实际客户端 UA 对比直连和反代响应。
- **502**：检查上游 TLS 证书、DNS、SNI 和 Nginx 错误日志 `tail -n 50 /var/log/nginx/error.log`。

## 安全边界

- 脚本和 Nginx 都在 root 权限下运行；不要 `curl | bash` 执行不可信源，先审阅项目文件。
- 反代 VPS 可以读取代理中转的 HTTP 请求和响应明文（TLS 在反代处终止）。
- 禁止把 `/etc/letsencrypt/live/*/privkey.pem` 上传 GitHub。
- 请确保入口 IP 是合法可申请证书的公网 IP，并且 TCP 80 从外网可达；本脚本不处理已有网站复杂迁移。
- 重复运行不会覆盖已有业务 Nginx 配置，不会强制重新签发已有证书；已有 Staging 证书需要人工处置。

参考：[Let's Encrypt 短期及 IP 证书公告](https://letsencrypt.org/2026/03/11/shorter-certs-certbot/) · [Certbot 官方文档](https://eff-certbot.readthedocs.io/en/stable/using.html)
