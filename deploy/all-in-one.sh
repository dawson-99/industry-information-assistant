#!/bin/bash
# 一键部署 + 数据库覆盖脚本 (服务器端执行)
set -e
SERVER_DIR="/opt/industry_assistant"
cd ${SERVER_DIR}

echo "=========================================="
echo "  行业信息助手 - 一键部署 + 数据覆盖"
echo "  $(date)"
echo "=========================================="

# ==================== 1. 中间件 ====================
echo ""
echo "=== [1/7] 启动中间件 ==="
docker compose up -d
sleep 3

# ==================== 2. 后端依赖 ====================
echo ""
echo "=== [2/7] 安装后端依赖 ==="
cd ${SERVER_DIR}/backend
python3.11 -m pip install -r requirements.txt -q 2>&1 | tail -2
echo "依赖安装完成"

# ==================== 3. 修复 app_main.py 导入路径 ====================
echo ""
echo "=== [3/7] 修复导入路径 ==="
if ! grep -q "sys.path.insert" ${SERVER_DIR}/backend/app/app_main.py; then
  sed -i "s|^from router import|import sys, os\nsys.path.insert(0, os.path.join(os.path.dirname(__file__)))\n\nfrom router import|" ${SERVER_DIR}/backend/app/app_main.py
  echo "已添加 sys.path"
else
  echo "sys.path 已存在，跳过"
fi

# ==================== 4. 初始化数据库表 ====================
echo ""
echo "=== [4/7] 初始化数据库表 ==="
python3.11 -c "
import sys, os
sys.path.insert(0, '${SERVER_DIR}/backend/app')
os.environ['POSTGRES_HOST'] = 'localhost'
os.environ['POSTGRES_PORT'] = '5432'
os.environ['POSTGRES_USER'] = 'postgres'
os.environ['POSTGRES_PASSWORD'] = 'postgres123'
os.environ['POSTGRES_DB'] = 'industry_assistant'
from core.database import engine, Base
from models import *
Base.metadata.create_all(bind=engine)
print('数据库表创建/更新完成')
"

# ==================== 5. 重启后端 ====================
echo ""
echo "=== [5/7] 重启后端 ==="
# 确保 systemd 使用 python3.11
sed -i 's|/usr/bin/python |/usr/bin/python3.11 |g' /etc/systemd/system/industry-backend.service 2>/dev/null || true
systemctl daemon-reload
systemctl enable industry-backend 2>/dev/null || true
systemctl restart industry-backend
sleep 4
systemctl status industry-backend --no-pager | head -5
curl -s http://127.0.0.1:8000/hello && echo "" && echo "后端健康检查通过" || echo "后端启动中..."

# ==================== 6. 构建前端 ====================
echo ""
echo "=== [6/7] 构建前端 ==="
cd ${SERVER_DIR}/frontend
if [ -d "dist" ] && [ -f "dist/index.html" ]; then
  echo "dist 已存在，跳过构建 (如需重新构建请先删除 dist 目录)"
else
  echo "开始构建前端 (服务器端构建较慢，约2-5分钟)..."
  npm install --silent 2>&1 | tail -2
  npm run build 2>&1 | tail -8
  echo "前端构建完成"
fi

# ==================== 7. 配置 Nginx ====================
echo ""
echo "=== [7/7] 配置 Nginx ==="
ln -sf /etc/nginx/sites-available/industry /etc/nginx/sites-enabled/
rm -f /etc/nginx/sites-enabled/default
nginx -t && systemctl reload nginx
echo "Nginx 配置完成"

# ==================== 8. 数据库覆盖 ====================
echo ""
echo "=========================================="
echo "  数据库覆盖 - 创建用户和记忆"
echo "=========================================="

# 删除旧数据
docker exec industry_postgres psql -U postgres -d industry_assistant -c "
DELETE FROM long_term_memories WHERE user_id IN (SELECT id FROM users WHERE username = '尼克狐尼克');
DELETE FROM users WHERE username = '尼克狐尼克';
SELECT '旧数据已清理' as status;
" 2>&1 | grep -v "^$"

# 创建用户 (bcrypt hash for '123456')
USER_ID="b7132f1d-9599-41a6-bc43-e45cf4a1830d"
docker exec industry_postgres psql -U postgres -d industry_assistant -c "
INSERT INTO users (id, username, email, hashed_password, is_active, created_at)
VALUES (
  '${USER_ID}',
  '尼克狐尼克',
  'hello.dawson2026@gmail.com',
  '\$2b\$12\$LJ3m4ys3YJXyMqNdGjPtbePFTWCxH2R9Fv5vTqKJ8fVLSsRx2GfGa',
  true,
  NOW()
);
SELECT '用户已创建: 尼克狐尼克' as status;
" 2>&1 | grep -v "^$"

echo "插入8条记忆..."

# 记忆1
docker exec industry_postgres psql -U postgres -d industry_assistant -c "
INSERT INTO long_term_memories (id, user_id, memory_type, summary, abstract, overview, key_insights, fields, links, backlinks, token_count, created_at)
VALUES (
  gen_random_uuid(),
  '${USER_ID}',
  'research_finding',
  '通过对固态电池产业链的深入研究，固态电池将在2028年前后实现量产，硫化物体系是目前最接近产业化的技术路线。宁德时代、比亚迪、丰田在固态电池专利布局上占据前三位置，国内企业在固态电解质材料方面具有先发优势。',
  '固态电池将于2028年前后进入量产阶段，硫化物路线最接近产业化',
  '[research_finding] | 固态电池将在2028年前后实现量产，硫化物体系是最接近产业化的技术路线。 | topic: 固态电池产业化进程',
  '{\"conclusion\": \"固态电池2028年量产，硫化物路线最优\", \"confidence\": \"0.85\", \"key_evidence\": \"头部企业量产时间表、专利布局数据\"}',
  '{\"topic\": \"固态电池产业化进程\", \"conclusion\": \"固态电池将在2028年前后实现量产，硫化物体系是最接近产业化的技术路线。\", \"confidence\": \"0.85\", \"sources\": \"宁德时代2025年报、丰田技术路线图\", \"related_entities\": \"宁德时代, 比亚迪, 丰田\"}',
  '[]',
  '[]',
  120,
  NOW()
);
" 2>&1 | grep -v "^$" && echo "  [1/8] research_finding: 固态电池产业化进程"

# 记忆2
docker exec industry_postgres psql -U postgres -d industry_assistant -c "
INSERT INTO long_term_memories (id, user_id, memory_type, summary, abstract, overview, key_insights, fields, links, backlinks, token_count, created_at)
VALUES (
  gen_random_uuid(),
  '${USER_ID}',
  'research_finding',
  '液态电解质的替代路线中，半固态电池作为过渡方案具有更高的产业化成熟度。清陶能源、卫蓝新能源等企业在半固态电池领域已实现小批量装车，能量密度达到360Wh/kg，比现有液态电池提升约30%。',
  '半固态电池作为过渡方案已实现小批量装车，能量密度达360Wh/kg',
  '[research_finding] | 半固态电池已实现小批量装车，能量密度达到360Wh/kg | topic: 半固态电池过渡方案',
  '{\"conclusion\": \"半固态电池是液态到全固态的最佳过渡方案\", \"confidence\": \"0.80\", \"key_evidence\": \"清陶能源装车数据、360Wh/kg实测值\"}',
  '{\"topic\": \"半固态电池过渡方案\", \"conclusion\": \"半固态电池作为过渡方案具有更高的产业化成熟度。\", \"confidence\": \"0.80\", \"sources\": \"清陶能源官方公告、卫蓝新能源产品手册\", \"related_entities\": \"清陶能源, 卫蓝新能源\"}',
  '[{\"to_uri\": \"memory:#固态电池产业化进程\", \"link_type\": \"related_to\", \"description\": \"半固态是固态电池的过渡方案\"}]',
  '[]',
  110,
  NOW()
);
" 2>&1 | grep -v "^$" && echo "  [2/8] research_finding: 半固态电池过渡方案"

# 记忆3
docker exec industry_postgres psql -U postgres -d industry_assistant -c "
INSERT INTO long_term_memories (id, user_id, memory_type, summary, abstract, overview, key_insights, fields, links, backlinks, token_count, created_at)
VALUES (
  gen_random_uuid(),
  '${USER_ID}',
  'research_finding',
  '固态电池上游材料方面，硫化锂(Li2S)是硫化物电解质的核心前驱体材料，目前每公斤成本约3000-5000元，占据硫化物电解质成本的60%以上。国内天赐材料、新宙邦、当升科技等企业正在积极布局硫化锂产能。',
  '硫化锂成本3000-5000元/公斤，占硫化物电解质成本60%以上',
  '[research_finding] | 硫化锂是硫化物电解质核心前驱体，成本占比超过60% | topic: 固态电池上游材料——硫化锂',
  '{\"conclusion\": \"硫化锂成本是硫化物固态电池商业化的瓶颈\", \"confidence\": \"0.90\", \"key_evidence\": \"供应链价格数据、企业产能规划\"}',
  '{\"topic\": \"固态电池上游材料——硫化锂\", \"conclusion\": \"硫化锂(Li2S)是硫化物电解质的核心前驱体材料。\", \"confidence\": \"0.90\", \"sources\": \"天赐材料投资者关系记录、新宙邦项目公示\", \"related_entities\": \"天赐材料, 新宙邦, 当升科技\"}',
  '[{\"to_uri\": \"memory:#固态电池产业化进程\", \"link_type\": \"derived_from\", \"description\": \"从固态电池产业化研究中延伸出的材料层面分析\"}]',
  '[]',
  125,
  NOW()
);
" 2>&1 | grep -v "^$" && echo "  [3/8] research_finding: 硫化锂上游材料"

# 记忆4
docker exec industry_postgres psql -U postgres -d industry_assistant -c "
INSERT INTO long_term_memories (id, user_id, memory_type, summary, abstract, overview, key_insights, fields, links, backlinks, token_count, created_at)
VALUES (
  gen_random_uuid(),
  '${USER_ID}',
  'research_finding',
  '在硫化物电解质制备工艺方面，高能球磨法是目前主流路线，但其批次一致性和放大生产仍存在挑战。液相法作为新兴工艺，在均匀性方面具有优势，但溶剂残留问题尚未完全解决。两种工艺路线的良率差距约15-20个百分点。',
  '高能球磨法为主流工艺，与液相法良率差距15-20个百分点',
  '[research_finding] | 硫化物电解质制备工艺对比，高能球磨法vs液相法 | topic: 硫化物电解质制备工艺',
  '{\"conclusion\": \"高能球磨法目前仍是主流，液相法良率有待提升\", \"confidence\": \"0.75\", \"key_evidence\": \"企业产线数据、学术论文对比\"}',
  '{\"topic\": \"硫化物电解质制备工艺\", \"conclusion\": \"高能球磨法是目前主流路线，但批次一致性存在挑战。\", \"confidence\": \"0.75\", \"sources\": \"学术论文综述、企业工艺路线对比\", \"related_entities\": \"三井金属, 出光兴产, 天赐材料\"}',
  '[{\"to_uri\": \"memory:#固态电池上游材料——硫化锂\", \"link_type\": \"related_to\", \"description\": \"硫化锂是球磨法制备电解质的关键原料\"}]',
  '[]',
  115,
  NOW()
);
" 2>&1 | grep -v "^$" && echo "  [4/8] research_finding: 硫化物电解质制备工艺"

# 记忆5
docker exec industry_postgres psql -U postgres -d industry_assistant -c "
INSERT INTO long_term_memories (id, user_id, memory_type, summary, abstract, overview, key_insights, fields, links, backlinks, token_count, created_at)
VALUES (
  gen_random_uuid(),
  '${USER_ID}',
  'industry_entity',
  '宁德时代在固态电池领域的布局涵盖硫化物、氧化物、聚合物三条技术路线，已公开专利超过200项。公司披露的凝聚态电池（半固态）单体能量密度达到500Wh/kg，计划2027年实现全固态电池小批量生产。宁德时代在全球动力电池市场份额约37%，在固态电池领域依然保持领先地位。',
  '宁德时代三条路线并行，凝聚态电池500Wh/kg，2027年全固态小批量',
  '[industry_entity] | 宁德时代 | entity_name: 宁德时代',
  '{\"entity_name\": \"宁德时代\", \"entity_type\": \"动力电池制造商\", \"industry\": \"新能源/动力电池\", \"key_facts\": \"全球动力电池市占率37%; 固态电池专利200+项; 凝聚态电池500Wh/kg; 2027年全固态小批量\"}',
  '{\"entity_name\": \"宁德时代\", \"entity_type\": \"动力电池制造商\", \"industry\": \"新能源/动力电池\", \"key_facts\": \"市占率37%; 专利200+项; 凝聚态电池500Wh/kg; 2027年全固态小批量\", \"last_researched\": \"2026-05-25\"}',
  '[{\"to_uri\": \"memory:#固态电池产业化进程\", \"link_type\": \"related_to\", \"description\": \"宁德时代是固态电池产业化的核心推动力\"}]',
  '[]',
  135,
  NOW()
);
" 2>&1 | grep -v "^$" && echo "  [5/8] industry_entity: 宁德时代"

# 记忆6
docker exec industry_postgres psql -U postgres -d industry_assistant -c "
INSERT INTO long_term_memories (id, user_id, memory_type, summary, abstract, overview, key_insights, fields, links, backlinks, token_count, created_at)
VALUES (
  gen_random_uuid(),
  '${USER_ID}',
  'industry_entity',
  '清陶能源成立于2016年，是国内半固态电池领域的头部企业，已完成D轮融资，估值超200亿元。公司与上汽集团深度绑定，半固态电池已搭载于智己L6车型，实测续航突破1000公里（CLTC工况）。其第一代半固态电池采用氧化物+聚合物的复合电解质路线，第二代产品将加入硫化物组分，目标能量密度400Wh/kg以上。',
  '清陶能源半固态电池搭载智己L6，续航1000+km，估值超200亿',
  '[industry_entity] | 清陶能源 | entity_name: 清陶能源',
  '{\"entity_name\": \"清陶能源\", \"entity_type\": \"固态电池创业企业\", \"industry\": \"新能源/固态电池\", \"key_facts\": \"2016年成立; D轮融资估值200亿+; 半固态电池装车智己L6; CLTC续航突破1000km; 氧化物+聚合物复合电解质\"}',
  '{\"entity_name\": \"清陶能源\", \"entity_type\": \"固态电池创业企业\", \"industry\": \"新能源/固态电池\", \"key_facts\": \"2016年成立; 估值200亿+; 装车智己L6; 续航1000+km\", \"last_researched\": \"2026-05-24\"}',
  '[{\"to_uri\": \"memory:#半固态电池过渡方案\", \"link_type\": \"related_to\", \"description\": \"清陶能源是半固态电池产业化的代表性企业\"}]',
  '[]',
  130,
  NOW()
);
" 2>&1 | grep -v "^$" && echo "  [6/8] industry_entity: 清陶能源"

# 记忆7
docker exec industry_postgres psql -U postgres -d industry_assistant -c "
INSERT INTO long_term_memories (id, user_id, memory_type, summary, abstract, overview, key_insights, fields, links, backlinks, token_count, created_at)
VALUES (
  gen_random_uuid(),
  '${USER_ID}',
  'industry_entity',
  '天赐材料是全球最大的电解液生产商，在锂离子电池材料领域市占率超过30%。公司正在向固态电池材料方向战略转型，已投资建设年产1000吨硫化锂中试线，计划2027年投产。此外，公司在LiFSI（新型锂盐）领域产能全球第一，该产品也是固态电解质的重要原料之一。',
  '天赐材料投建千吨级硫化锂中试线，转型固态电池材料',
  '[industry_entity] | 天赐材料 | entity_name: 天赐材料',
  '{\"entity_name\": \"天赐材料\", \"entity_type\": \"电池材料供应商\", \"industry\": \"新能源/电池材料\", \"key_facts\": \"全球最大电解液生产商; 材料市占率30%+; 千吨硫化锂中试线在建; LiFSI产能全球第一; 2027年硫化锂投产\"}',
  '{\"entity_name\": \"天赐材料\", \"entity_type\": \"电池材料供应商\", \"industry\": \"新能源/电池材料\", \"key_facts\": \"全球最大电解液商; 硫化锂中试线; LiFSI产能第一; 2027年投产\", \"last_researched\": \"2026-05-23\"}',
  '[{\"to_uri\": \"memory:#固态电池上游材料——硫化锂\", \"link_type\": \"derived_from\", \"description\": \"涉及天赐材料的硫化锂产能布局\"}, {\"to_uri\": \"memory:#硫化物电解质制备工艺\", \"link_type\": \"related_to\", \"description\": \"天赐材料涉及硫化锂原料供应\"}]',
  '[]',
  140,
  NOW()
);
" 2>&1 | grep -v "^$" && echo "  [7/8] industry_entity: 天赐材料"

# 记忆8
docker exec industry_postgres psql -U postgres -d industry_assistant -c "
INSERT INTO long_term_memories (id, user_id, memory_type, summary, abstract, overview, key_insights, fields, links, backlinks, token_count, created_at)
VALUES (
  gen_random_uuid(),
  '${USER_ID}',
  'preference',
  '用户专注于固态电池产业链上游材料环节的研究，特别关注硫化物电解质相关企业。偏好包含具体产能数据和成本数据的深度分析，对技术路线对比（如高能球磨法vs液相法）有强烈兴趣。用户认为硫化物体系是最终技术路线，但对半固态过渡方案持开放态度。',
  '用户专注固态电池上游材料，偏好产能/成本数据，对技术路线对比有强兴趣',
  '[preference] | 固态电池上游材料研究偏好 | preference_type: research_focus',
  '{\"preference_type\": \"research_focus\", \"value\": \"固态电池上游材料、硫化物电解质、产能与成本数据、技术路线对比\"}',
  '{\"preference_type\": \"research_focus\", \"value\": \"固态电池上游材料; 硫化物电解质; 产能与成本数据; 技术路线对比; 企业供应链分析\"}',
  '[]',
  '[]',
  95,
  NOW()
);
" 2>&1 | grep -v "^$" && echo "  [8/8] preference: 研究偏好"

# ==================== 验证 ====================
echo ""
echo "=========================================="
echo "  验证结果"
echo "=========================================="
docker exec industry_postgres psql -U postgres -d industry_assistant -c "
SELECT
  u.username,
  COUNT(m.id) as memory_count
FROM users u
LEFT JOIN long_term_memories m ON u.id = m.user_id
WHERE u.username = '尼克狐尼克'
GROUP BY u.username;
"

echo ""
echo "记忆详情:"
docker exec industry_postgres psql -U postgres -d industry_assistant -c "
SELECT memory_type, abstract FROM long_term_memories
WHERE user_id = '${USER_ID}'
ORDER BY created_at;
"

echo ""
echo "后端 API 测试:"
curl -s http://127.0.0.1:8000/api/memories?limit=5 | head -c 200
echo ""

echo ""
echo "=========================================="
echo "  部署 + 数据库覆盖 全部完成!"
echo "  $(date)"
echo "=========================================="
