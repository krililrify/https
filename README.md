# Root HTTPS

在 Ubuntu 22.04 / 24.04 VPS 上自动安装 Nginx、申请 Let's Encrypt 公网 IPv4 HTTPS 证书并设置自动续签。

## 安装

```bash
sudo apt-get update && sudo apt-get install -y git && git clone https://github.com/krililrify/https.git && cd https && sudo bash install.sh
```

默认自动获取公网 IPv4。需要指定 IP 时，在项目目录执行：

```bash
sudo env PUBLIC_IP=你的公网IPv4 bash install.sh
```

安装完成后，自行参考 `examples/site1.conf.example` 配置 `/etc/nginx/conf.d/site1.conf`，再执行：

```bash
sudo nginx -t && sudo systemctl reload nginx
```
