#!/bin/bash
# 百度云 BCC 初始化脚本 (Ubuntu 22.04)
# 用法: ssh 登录后执行 bash setup-server.sh

set -e

echo "=== 1. 系统更新 ==="
apt update
DEBIAN_FRONTEND=noninteractive apt-get -o Dpkg::Options::='--force-confdef' -o Dpkg::Options::='--force-confold' upgrade -y

echo "=== 2. 安装基础工具 ==="
apt install -y curl wget git vim nginx software-properties-common

echo "=== 3. 安装 Docker ==="
curl -fsSL https://get.docker.com | bash
usermod -aG docker $USER

echo "=== 4. 安装 Docker Compose ==="
apt install -y docker-compose-plugin

echo "=== 5. 安装 Node.js 20 ==="
curl -fsSL https://deb.nodesource.com/setup_20.x | bash -
apt install -y nodejs

echo "=== 6. 安装 Python 3.11 ==="
add-apt-repository -y ppa:deadsnakes/ppa
apt update
apt install -y python3.11 python3.11-venv python3.11-dev python3-pip
update-alternatives --install /usr/bin/python python /usr/bin/python3.11 1
update-alternatives --install /usr/bin/pip pip /usr/bin/pip3 1

echo "=== 7. 创建项目目录 ==="
mkdir -p /opt/industry_assistant

echo "=== 完成! 请退出重新登录以使 docker 权限生效 ==="
echo "重新登录后执行: docker info 验证"
