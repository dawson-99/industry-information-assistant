# 行业研究助手 — 记忆层升级设计

**日期:** 2026-05-27  
**路线:** 渐进增强（Option A）— 在现有 MemoryService 基础上结构化升级  
**参考:** OpenViking 记忆层设计

---

## 一、目标

在现有 PostgreSQL + Milvus 记忆系统基础上，引入 OpenViking 的以下设计模式，使记忆系统支持：
1. YAML 配置化的记忆类型（无需改代码即可新增类型）
2. Patch 增量更新替代全量覆盖（降低 LLM token 消耗，保留历史细节）
3. 三层摘要体系（L0 abstract → L1 overview → L2 detail，分级加载降低 prompt token）
4. 记忆间链接关系（构建研究知识图谱）

---

## 二、记忆类型

首批跑通 3 种类型（后续可通过 YAML 扩展）：

| 类型 | 说明 | 文件名模板 |
|------|------|-----------|
| `research_finding` | 研究发现与结论，跨会话复用 | `{topic}.md` |
| `industry_entity` | 研究过的公司/行业/技术实体 | `{entity_name}.md` |
| preferences | 用户偏好（保留现有逻辑，暂不迁移到 YAML） | — |

---

## 三、数据模型变更

### LongTermMemory 表（`backend/app/models/chat.py`）

新增字段：

| 字段 | 类型 | 说明 |
|------|------|------|
| `memory_type` | VARCHAR(64) | 记忆类型（research_finding / industry_entity / preference） |
| `abstract` | TEXT | L0 摘要（约 50 字） |
| `overview` | TEXT | L1 概览（约 150 字） |
| `fields` | JSONB | 动态字段（如 topic、conclusion、confidence、entity_name 等，由 schema 定义） |
| `links` | JSONB | 正向链接 `[{"to_uri": "...", "link_type": "..."}]` |
| `backlinks` | JSONB | 反向链接（系统自动维护） |

现有 `summary` 字段保留，作为 L2 完整内容。`memory_type` 加索引。

---

## 四、YAML Schema 配置

目录：`backend/app/config/memory_types/`

### research_finding.yaml

```yaml
memory_type: research_finding
description: |
  研究发现与结论 - 跨会话可复用的研究成果。
  提取研究过程中形成的事实结论、数据分析结果、趋势判断。

directory: "user/{user_id}/memories/findings"
filename_template: "{topic}.md"
embedding_template: "研究主题: {topic}\n结论: {conclusion}"

fields:
  - name: topic
    type: string
    merge_op: immutable
  - name: conclusion
    type: string
    merge_op: patch       # 增量补充新证据
  - name: confidence
    type: string
    merge_op: replace
  - name: sources
    type: string
    merge_op: sum          # 追加新来源
  - name: related_entities
    type: string
    merge_op: sum
```

### industry_entity.yaml

```yaml
memory_type: industry_entity
description: |
  行业实体 - 记录研究过的公司、行业、技术等实体的基本事实。

directory: "user/{user_id}/memories/entities"
filename_template: "{entity_name}.md"
embedding_template: "实体: {entity_name}\n行业: {industry}\n关键事实: {key_facts}"

fields:
  - name: entity_name
    type: string
    merge_op: immutable
  - name: entity_type
    type: string
    merge_op: replace
  - name: industry
    type: string
    merge_op: replace
  - name: key_facts
    type: string
    merge_op: patch
  - name: last_researched
    type: string
    merge_op: replace
```

---

## 五、新增/改动的文件

### 5.1 新增 `backend/app/service/memory_type_registry.py`

MemoryTypeRegistry — 加载 YAML 配置，提供 schema 查询。

```
MemoryTypeRegistry
├── __init__():          启动时扫描 config/memory_types/*.yaml
├── get(type_name) -> MemoryTypeSchema
├── list_all() -> List[MemoryTypeSchema]
└── list_search_scopes(user_id) -> List[dir_uri]
```

依赖：PyYAML。

### 5.2 新增 `backend/app/service/memory_merge.py`

四种合并策略：

```
apply_merge(current_value, patch_value, merge_op) -> new_value
├── patch:     SEARCH/REPLACE 文本替换
├── replace:   直接用 patch_value 覆盖
├── sum:       追加到末尾（"\n" 拼接）
└── immutable: 忽略 patch_value，返回 current_value
```

### 5.3 改动 `backend/app/service/memory_service.py`

核心变更：

1. **prompt 重构** — 按 memory_type 输出结构化记忆列表（每条含 action、fields、links）
2. **增量合并** — 查询同主题/同实体已有记忆，按 merge_op 合并 fields 后写入
3. **三层摘要** — LLM 生成 conclusion 时同步生成 abstract 和 overview
4. **链接解析** — 解析 LLM 输出的临时 page_id 为真实 URI，维护 links/backlinks
5. **向量化** — 用 embedding_template 渲染向量文本

### 5.4 改动 `backend/app/models/chat.py`

LongTermMemory 模型新增字段（见第三章）。

---

## 六、检索改进

`build_memory_context` 返回值从 `str` 改为 `dict`：

```python
{
    "context_text": "...",       # 拼接好的 prompt 文本
    "memory_ids": ["id1", ...],  # 引用的记忆 ID
}
```

检索流程：

```
Step 1 — Milvus 向量搜索 → top-10，只读 abstract
Step 2 — 取前 5 条的 overview 拼接 context_text（控制在 800 tokens 内）
Step 3 — 返回 memory_ids，前端按需通过 /memory/{id} 获取 L2 完整内容
```

---

## 七、链接关系

链接类型限定 3 种：
- `derived_from` — 结论基于某实体/发现推导
- `related_to` — 一般关联
- `contradicts` — 后续研究推翻了早期结论

LLM 每条记忆输出可选的 `links` 列表，系统侧解析 `page_id → URI` 后写入 links/backlinks 字段。

---

## 八、不在本次范围

- 多租户隔离（当前只有单 user_id）
- ReAct 记忆提取循环（研究流程本身已是 ReAct，记忆提取简化为研究结束后的单次总结调用）
- VikingFS / 文件系统层（保留 PostgreSQL + Milvus）
- preferences 类型的 YAML 迁移（后续再做）
- Overview 自动生成（后续迭代）
