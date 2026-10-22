# SOCKS5-only for Ubuntu 24.04

一个只做 SOCKS5 的最小部署包。相比 `argosbx`，不包含 WARP、Argo、订阅、证书、多协议和 `.bashrc` 注入。

## 组成

- Xray-core `v26.3.27`，使用官方 Linux x86_64 发布包，安装前校验 SHA256
- 单个 SOCKS5 inbound，用户名/密码认证
- 专用系统用户 `xray-socks5`
- systemd 服务 `xray-socks5`，带沙箱限制
- 默认关闭 UDP；默认阻断私网、回环和云元数据地址
- 可选来源 IP/CIDR 白名单

## 安装

将整个目录上传到 VPS，例如：

```bash
scp -r socks5-only root@VPS_IP:/root/
ssh root@VPS_IP
cd /root/socks5-only
chmod +x install.sh update.sh uninstall.sh
```

仅使用 SOCKS5，开放任意来源：

```bash
sudo ./install.sh --port 23456
```

推荐：只允许固定来源 IP：

```bash
sudo ./install.sh --port 23456 --allow-cidr 203.0.113.10/32
```

允许一个网段并开启 UDP：

```bash
sudo ./install.sh --port 23456 --allow-cidr 203.0.113.0/24 --udp
```

自定义账号：

```bash
sudo ./install.sh --port 23456 \
  --username socksuser \
  --password '替换成至少12位随机密码'
```

安装完成后会输出客户端参数。使用 `--force` 重装时，旧配置和 unit 会备份到 `/var/backups/xray-socks5`。

## 一键远程安装

将 `install.sh` 上传到可公开访问的地址后，可以保持和 `argosbx` 类似的一行式安装：

```bash
sopt="3223" uuid="自定义账号密码" \
  bash <(curl -fLsS https://raw.githubusercontent.com/OWNER/REPO/COMMIT/socks5-only/install.sh)
```

- `sopt`：SOCKS5 端口
- `uuid`：同时作为用户名和密码
- 建议使用固定的 commit SHA 或 release 地址，不要长期直接使用 `main`
- 必须以 root 运行；如果当前是普通用户，先执行 `sudo -i`

这条命令只负责安装 SOCKS5，不会自动修改云厂商安全组或 UFW。端口仍需按下面的防火墙说明放行。

## 修改 sopt 和 uuid

`sopt` 和 `uuid` 是安装时传入的环境变量，不保存在 VPS 的独立配置文件中。可修改的位置有三个：

1. 直接改一键命令开头：

```bash
sopt="3223" uuid="新的账号密码" bash <(curl -fLsS <install.sh地址>)
```

2. 使用私用模板 `deploy.local.example.sh`：复制为 `deploy.local.sh`，修改文件顶部的 `SOPT` 和 `UUID`，之后每次重置 VPS 只需执行：

```bash
bash deploy.local.sh --allow-cidr 你的公网IP/32
```

`deploy.local.sh` 已加入 `.gitignore`，不要上传到公开 GitHub。公开仓库只放 `install.sh`。

模板中的 `UUID="CHANGE_ME_BEFORE_USE"` 是占位符，运行前必须替换；脚本会拒绝使用这个占位值。

3. 修改 `install.sh` 里 `PORT="${sopt:-23456}"` 等默认值只适合改默认端口，不建议把密码写进公开仓库。

已经安装但不重置 VPS 时，可以用新参数加 `--force` 重装：

```bash
sopt="新端口" uuid="新密码" bash <(curl -fLsS <install.sh地址>) --force
```

## 防火墙

脚本不会自动修改系统防火墙。需要放行 TCP 端口；只有开启 UDP 时才需要放行 UDP。

UFW 示例：

```bash
sudo ufw allow from 203.0.113.10 to any port 23456 proto tcp
sudo ufw status
```

同时还要在 VPS 云厂商安全组放行对应端口。不要为了省事关掉整个防火墙。

## 客户端

- 类型：`SOCKS5`
- 服务器：VPS 公网 IP
- 端口：安装时指定的端口
- 用户名/密码：安装结束输出，或查看 `/etc/xray-socks5/config.json`
- DNS：建议使用代理端解析，例如 `curl --socks5-hostname`

测试：

```bash
curl --socks5-hostname VPS_IP:23456 \
  --proxy-user 'USERNAME:PASSWORD' \
  https://api.ipify.org
```

应返回 VPS 的公网 IP。

## 运维

```bash
systemctl status xray-socks5
journalctl -u xray-socks5 -f
```

修改配置后：

```bash
systemctl restart xray-socks5
```

## 更新

更新脚本只替换二进制，不修改账号、端口或路由。必须同时提供目标版本和 SHA256：

```bash
sudo ./update.sh --version v26.3.27 \
  --sha256 23cd9af937744d97776ee35ecad4972cf4b2109d1e0fe6be9930467608f7c8ae
```

新二进制会先用现有配置跑 `-test`，启动失败会自动回滚。

## 卸载

```bash
sudo ./uninstall.sh
```

非交互：

```bash
sudo ./uninstall.sh --yes
```

配置会先备份到 `/var/backups/xray-socks5`。防火墙和云安全组规则需要手动清理。

## 安全说明

SOCKS5 本身不加密，用户名、密码和流量在公网链路上不是加密传输。此部署适合临时使用或受控来源；长期暴露在公网时，建议限制来源 IP，或改用带 TLS 的协议。

默认配置会把私网、回环、链路本地和 `169.254.169.254` 等地址路由到 blackhole，避免代理被用来访问 VPS 内网或云元数据。
