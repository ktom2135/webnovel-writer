#Requires -Version 5.1
<#
.SYNOPSIS
    在 Azure 东京区域（japaneast）一键部署 WireGuard VPN
.DESCRIPTION
    创建 B1s VM (Ubuntu 24.04)，安装配置 WireGuard，
    生成客户端配置文件保存到本地。
.PARAMETER ResourceGroup
    资源组名称
.PARAMETER VmName
    VM 名称
.PARAMETER AdminPassword
    VM 管理员密码（Ubuntu 默认用户 azureuser）
.PARAMETER ClientName
    客户端名称（生成的 .conf 文件名）
#>

param(
    [string]$ResourceGroup  = "rg-vpn-japaneast",
    [string]$VmName         = "vm-wireguard",
    [string]$AdminPassword  = "",
    [string]$ClientName     = "phone",
    [string]$Location       = "japaneast"
)

$ErrorActionPreference = "Stop"

# ── 检查 Azure CLI ───────────────────────────────────────
try { az --version | Out-Null } catch {
    Write-Host "请先安装 Azure CLI: https://aka.ms/installazurecliwindows" -ForegroundColor Red
    exit 1
}

# ── 登录检查 ──────────────────────────────────────────────
$account = az account show 2>$null
if (-not $account) {
    Write-Host "正在登录 Azure..." -ForegroundColor Yellow
    az login --use-device-code | Out-Null
}

# ── 密码 ──────────────────────────────────────────────────
if (-not $AdminPassword) {
    Add-Type -AssemblyName System.Web
    $AdminPassword = [System.Web.Security.Membership]::GeneratePassword(20, 5)
    Write-Host "自动生成密码: $AdminPassword" -ForegroundColor Cyan
    Write-Host "请保存好这个密码！" -ForegroundColor Yellow
}

Write-Host "`n========================================" -ForegroundColor Green
Write-Host "  开始部署 WireGuard VPN (东京)" -ForegroundColor Green
Write-Host "========================================`n" -ForegroundColor Green

# ── 创建资源组 ───────────────────────────────────────────
Write-Host "[1/5] 创建资源组..." -ForegroundColor Yellow
az group create --name $ResourceGroup --location $Location --output none

# ── 创建 NSG + 开放端口 ─────────────────────────────────
Write-Host "[2/5] 创建网络安全组..." -ForegroundColor Yellow
az network nsg create --resource-group $ResourceGroup --name "${VmName}-nsg" --location $Location --output none
# SSH
az network nsg rule create --resource-group $ResourceGroup --nsg-name "${VmName}-nsg" `
    --name "SSH" --protocol Tcp --priority 1000 --destination-port-ranges 22 --access Allow --output none
# WireGuard
az network nsg rule create --resource-group $ResourceGroup --nsg-name "${VmName}-nsg" `
    --name "WireGuard" --protocol Udp --priority 1010 --destination-port-ranges 51820 --access Allow --output none

# ── 创建 B1s VM ──────────────────────────────────────────
Write-Host "[3/5] 创建 B1s VM (Ubuntu 24.04)..." -ForegroundColor Yellow
az vm create `
    --resource-group $ResourceGroup `
    --name $VmName `
    --location $Location `
    --image "Ubuntu2404" `
    --size "Standard_B1s" `
    --admin-username "azureuser" `
    --admin-password $AdminPassword `
    --nsg "${VmName}-nsg" `
    --public-ip-sku Standard `
    --output table

# ── 获取公网 IP ──────────────────────────────────────────
$publicIp = az vm show -d --resource-group $ResourceGroup --name $VmName --query publicIps -o tsv
Write-Host "  公网 IP: $publicIp" -ForegroundColor Green

# ── 安装配置 WireGuard ───────────────────────────────────
Write-Host "[4/5] 安装 WireGuard..." -ForegroundColor Yellow

$setupScript = @'
#!/bin/bash
set -e

# 安装 WireGuard
apt-get update -qq
apt-get install -y -qq wireguard-tools qrencode

# 生成服务器密钥
cd /etc/wireguard
umask 077
wg genkey | tee server.key | wg pubkey > server.pub
SERVER_PRIV=$(cat server.key)
SERVER_PUB=$(cat server.pub)

# 生成客户端密钥
wg genkey | tee client.key | wg pubkey > client.pub
CLIENT_PRIV=$(cat client.key)
CLIENT_PUB=$(cat client.pub)

# 写服务端配置
cat > /etc/wireguard/wg0.conf << EOF
[Interface]
PrivateKey = ${SERVER_PRIV}
Address = 10.0.0.1/24
ListenPort = 51820

# 启用 NAT 转发
PostUp = iptables -A FORWARD -i wg0 -j ACCEPT; iptables -t nat -A POSTROUTING -o eth0 -j MASQUERADE
PostDown = iptables -D FORWARD -i wg0 -j ACCEPT; iptables -t nat -D POSTROUTING -o eth0 -j MASQUERADE

[Peer]
PublicKey = ${CLIENT_PUB}
AllowedIPs = 10.0.0.2/32
EOF

# 启用 IP 转发
sysctl -w net.ipv4.ip_forward=1 > /dev/null
echo "net.ipv4.ip_forward=1" > /etc/sysctl.d/99-wireguard.conf

# 启动 WireGuard
systemctl enable wg-quick@wg0
systemctl start wg-quick@wg0

# 保存客户端配置
CLIENT_CONF="/root/client.conf"
cat > ${CLIENT_CONF} << EOF
[Interface]
PrivateKey = ${CLIENT_PRIV}
Address = 10.0.0.2/24
DNS = 8.8.8.8, 1.1.1.1

[Peer]
PublicKey = ${SERVER_PUB}
Endpoint = __SERVER_IP__:51820
AllowedIPs = 0.0.0.0/0
PersistentKeepalive = 25
EOF

# 输出公钥和私钥供调试
echo "=== 服务端公钥 ==="
cat /etc/wireguard/server.pub
echo "=== 客户端配置文件 (base64) ==="
base64 -w0 ${CLIENT_CONF}
echo ""
'@

$setupScript = $setupScript.Replace("__SERVER_IP__", $publicIp)

# 用 az vm run-command 执行
Write-Host "  执行远程配置..." -ForegroundColor Yellow
$result = az vm run-command invoke `
    --resource-group $ResourceGroup `
    --name $VmName `
    --command-id RunShellScript `
    --scripts $setupScript `
    --output json | ConvertFrom-Json

$outputLines = $result.value.message -split "`n"
$serverPub = ""
$clientBase64 = ""
$capture = $false

foreach ($line in $outputLines) {
    if ($line -match "服务端公钥") { $capture = "pub" }
    elseif ($line -match "客户端配置文件") { $capture = "conf" }
    elseif ($capture -eq "pub" -and $line.Trim()) { $serverPub = $line.Trim(); $capture = $null }
    elseif ($capture -eq "conf" -and $line.Trim()) { $clientBase64 = $line.Trim(); $capture = $null }
    Write-Host "  $line" -ForegroundColor Gray
}

# ── 保存客户端配置 ───────────────────────────────────────
Write-Host "[5/5] 保存客户端配置..." -ForegroundColor Yellow

if ($clientBase64) {
    $clientConf = [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($clientBase64))
    $confPath = Join-Path $PWD "$ClientName.conf"
    Set-Content -Path $confPath -Value $clientConf -Encoding UTF8
    Write-Host "  配置文件: $confPath" -ForegroundColor Green
    Write-Host "  服务端公钥: $serverPub" -ForegroundColor Green
} else {
    Write-Host "  [警告] 未获取到客户端配置，请手动登录 VM 查看 /root/client.conf" -ForegroundColor Yellow
}

# ── 完成 ──────────────────────────────────────────────────
Write-Host "`n========================================" -ForegroundColor Green
Write-Host "  部署完成!" -ForegroundColor Green
Write-Host "========================================" -ForegroundColor Green
Write-Host "  VM 公网 IP: $publicIp" -ForegroundColor Cyan
if ($clientBase64) {
    Write-Host "  客户端配置: $confPath" -ForegroundColor Cyan
    Write-Host "  用 WireGuard 客户端导入此文件即可连接" -ForegroundColor Cyan
}
Write-Host "  SSH: ssh azureuser@$publicIp" -ForegroundColor Cyan
Write-Host "  密码: $AdminPassword" -ForegroundColor Yellow
Write-Host "========================================" -ForegroundColor Green