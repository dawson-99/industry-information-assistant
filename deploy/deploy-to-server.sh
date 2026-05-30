#!/bin/bash
# 本地执行：增量部署到百度云 BCC 服务器
# 用法: bash deploy-to-server.sh <服务器IP> [ssh用户]
# 示例: bash deploy-to-server.sh 120.48.xx.xx root

set -e

SERVER_IP="${1:?请提供服务器IP: bash deploy-to-server.sh <IP>}"
SSH_USER="${2:-root}"
SERVER_DIR="/opt/industry_assistant"

echo "=== 部署到 ${SSH_USER}@${SERVER_IP}:${SERVER_DIR} ==="

# 1. 创建服务器目录
ssh ${SSH_USER}@${SERVER_IP} "mkdir -p ${SERVER_DIR}"

# 2. 同步项目代码（排除不需要的文件）
echo "同步代码..."
rsync -avz --delete \
    --exclude 'node_modules' \
    --exclude '__pycache__' \
    --exclude '*.pyc' \
    --exclude '.git' \
    --exclude '.DS_Store' \
    --exclude '*.log' \
    --exclude 'data/' \
    --exclude 'deploy/' \
    --exclude 'venv/' \
    --exclude '.env' \
    --exclude 'frontend/.env' \
    --exclude 'dist/' \
    /Users/xuruihang/Desktop/简历项目/industry_information_assistant/ \
    ${SSH_USER}@${SERVER_IP}:${SERVER_DIR}/

# 3. 上传生产环境配置
echo "上传生产配置..."
scp deploy/.env.production ${SSH_USER}@${SERVER_IP}:${SERVER_DIR}/backend/.env
scp deploy/.env.production.frontend ${SSH_USER}@${SERVER_IP}:${SERVER_DIR}/frontend/.env
scp deploy/docker-compose.prod.yml ${SSH_USER}@${SERVER_IP}:${SERVER_DIR}/docker-compose.yml
scp deploy/nginx-industry.conf ${SSH_USER}@${SERVER_IP}:/etc/nginx/sites-available/industry
scp deploy/industry-backend.service ${SSH_USER}@${SERVER_IP}:/etc/systemd/system/industry-backend.service

# 4. 远程执行部署
echo "服务器端安装依赖并启动服务..."
ssh ${SSH_USER}@${SERVER_IP} "bash -s" << 'ENDSSH'
set -e
SERVER_DIR="/opt/industry_assistant"
cd ${SERVER_DIR}

# 启动中间件
echo "启动中间件..."
docker compose up -d

# 安装 Python 依赖
echo "安装后端依赖..."
cd backend
pip install -r requirements.txt

# 初始化数据库
echo "初始化数据库..."
python -c "
from app.core.database import engine, Base
from app.models import *
Base.metadata.create_all(bind=engine)
print('数据库表创建完成')
"

# 配置 systemd 并启动后端
echo "配置后端服务..."
systemctl daemon-reload
systemctl enable industry-backend
systemctl restart industry-backend

# 构建前端
echo "构建前端..."
cd ${SERVER_DIR}/frontend
npm install
npm run build

# 配置 Nginx
echo "配置 Nginx..."
ln -sf /etc/nginx/sites-available/industry /etc/nginx/sites-enabled/
# 删除默认站点
rm -f /etc/nginx/sites-enabled/default
nginx -t && systemctl reload nginx

echo "=== 部署完成! ==="
echo "访问 http://${SERVER_IP} 查看前端"
echo "后端健康检查: curl http://127.0.0.1:8000/hello"
echo "查看后端日志: journalctl -u industry-backend -f"
ENDSSH

echo "=== 全部完成 ==="
