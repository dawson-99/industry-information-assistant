# 记忆层升级实现计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 在现有 MemoryService 基础上引入 OpenViking 设计模式 — YAML 配置化记忆类型、patch 增量更新、三层摘要、记忆链接。

**Architecture:** 新增 MemoryTypeRegistry（加载 YAML schema）+ memory_merge（四种合并策略），重构 MemoryService 的总结 prompt 和 create 流程使其支持结构化输出和增量合并，改进检索为三层分级加载。不改动 PostgreSQL + Milvus 存储层。

**Tech Stack:** Python 3.9+, FastAPI, SQLAlchemy, PyYAML, Milvus (pymilvus), DashScope text-embedding-v4

---

### Task 1: 数据库迁移 — LongTermMemory 表新增字段

**Files:**
- Create: `backend/alembic/versions/001_add_memory_fields.py` (手动 SQL 脚本)
- 或直接在模型中声明后通过 `Base.metadata.create_all` 无法增量加列，改为写 SQL 迁移脚本

- [ ] **Step 1: 创建迁移 SQL**

```sql
-- backend/migrations/001_add_memory_fields.sql
ALTER TABLE long_term_memories ADD COLUMN IF NOT EXISTS memory_type VARCHAR(64);
ALTER TABLE long_term_memories ADD COLUMN IF NOT EXISTS abstract TEXT;
ALTER TABLE long_term_memories ADD COLUMN IF NOT EXISTS overview TEXT;
ALTER TABLE long_term_memories ADD COLUMN IF NOT EXISTS fields JSONB DEFAULT '{}'::jsonb;
ALTER TABLE long_term_memories ADD COLUMN IF NOT EXISTS links JSONB DEFAULT '[]'::jsonb;
ALTER TABLE long_term_memories ADD COLUMN IF NOT EXISTS backlinks JSONB DEFAULT '[]'::jsonb;
CREATE INDEX IF NOT EXISTS idx_long_term_memories_memory_type ON long_term_memories(memory_type);
```

- [ ] **Step 2: 执行迁移**

```bash
docker exec -i $(docker ps -qf "name=postgres") psql -U postgres -d industry_assistant < backend/migrations/001_add_memory_fields.sql
```

验证: 重启后端，确认无启动错误。

- [ ] **Step 3: 验证表结构**

```bash
docker exec -i $(docker ps -qf "name=postgres") psql -U postgres -d industry_assistant -c "\d long_term_memories"
```

预期: 看到新增的 6 个字段 + 1 个索引。

---

### Task 2: 更新 LongTermMemory ORM 模型

**Files:**
- Modify: `backend/app/models/chat.py:73-88`
- 新增: `backend/app/schemas/memory_config.py` (Pydantic schema 定义)

- [ ] **Step 1: 定义 Pydantic schema（供 YAML 解析和代码内使用）**

创建 `backend/app/schemas/memory_config.py`:

```python
"""记忆类型配置 Pydantic Schema"""
from enum import Enum
from typing import Any, Optional
from pydantic import BaseModel, Field


class MergeOp(str, Enum):
    PATCH = "patch"
    REPLACE = "replace"
    SUM = "sum"
    IMMUTABLE = "immutable"


class FieldType(str, Enum):
    STRING = "string"


class MemoryField(BaseModel):
    name: str
    type: FieldType = FieldType.STRING
    description: str = ""
    merge_op: MergeOp = MergeOp.PATCH


class MemoryTypeSchema(BaseModel):
    memory_type: str
    description: str = ""
    directory: str = ""
    filename_template: str = ""
    embedding_template: str = ""
    fields: list[MemoryField] = Field(default_factory=list)
```

- [ ] **Step 2: 更新 LongTermMemory 模型**

编辑 `backend/app/models/chat.py:73-88`，替换 `LongTermMemory` 类：

```python
class LongTermMemory(Base):
    """长期记忆模型"""
    __tablename__ = "long_term_memories"

    id = Column(UUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    user_id = Column(UUID(as_uuid=True), ForeignKey("users.id", ondelete="CASCADE"))
    session_id = Column(UUID(as_uuid=True), ForeignKey("chat_sessions.id", ondelete="SET NULL"), nullable=True)
    memory_type = Column(String(64), default="preference")  # 新增
    summary = Column(Text, nullable=False)                   # L2 完整内容
    abstract = Column(Text)                                  # 新增: L0 摘要
    overview = Column(Text)                                  # 新增: L1 概览
    key_insights = Column(JSONB)                             # 保留兼容
    fields = Column(JSONB)                                   # 新增: 动态字段
    links = Column(JSONB)                                    # 新增: 正向链接
    backlinks = Column(JSONB)                                # 新增: 反向链接
    milvus_ids = Column(ARRAY(Text))
    token_count = Column(Integer)
    created_at = Column(DateTime, default=datetime.utcnow)

    # 关系
    user = relationship("User", back_populates="memories")
    session = relationship("ChatSession", back_populates="memories")
```

- [ ] **Step 3: 验证模型导入**

```bash
cd backend && python -c "from models.chat import LongTermMemory; print('OK')"
```

---

### Task 3: 创建 YAML Schema 配置文件

**Files:**
- Create: `backend/app/config/memory_types/research_finding.yaml`
- Create: `backend/app/config/memory_types/industry_entity.yaml`

- [ ] **Step 1: 创建 `backend/app/config/memory_types/__init__.py`**

```python
# 空文件，使目录成为 Python 包
```

- [ ] **Step 2: 创建 `research_finding.yaml`**

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
    description: 研究主题，作为唯一标识
    merge_op: immutable
  - name: conclusion
    type: string
    description: 核心结论，支持增量补充
    merge_op: patch
  - name: confidence
    type: string
    description: 结论置信度（高/中/低/推测）
    merge_op: replace
  - name: sources
    type: string
    description: 信息来源列表
    merge_op: sum
  - name: related_entities
    type: string
    description: 相关行业实体名称列表
    merge_op: sum
```

- [ ] **Step 3: 创建 `industry_entity.yaml`**

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
    description: 实体名称，唯一标识
    merge_op: immutable
  - name: entity_type
    type: string
    description: 实体类型（company/industry/technology/product/policy）
    merge_op: replace
  - name: industry
    type: string
    description: 所属行业
    merge_op: replace
  - name: key_facts
    type: string
    description: 关键事实，支持增量更新
    merge_op: patch
  - name: last_researched
    type: string
    description: 最近研究时间
    merge_op: replace
```

- [ ] **Step 4: 验证 YAML 可解析**

```bash
cd backend && python -c "
import yaml
with open('app/config/memory_types/research_finding.yaml') as f:
    print(yaml.safe_load(f)['memory_type'])
with open('app/config/memory_types/industry_entity.yaml') as f:
    print(yaml.safe_load(f)['memory_type'])
"
```

预期输出:
```
research_finding
industry_entity
```

---

### Task 4: 创建 memory_merge.py — 四种合并策略

**Files:**
- Create: `backend/app/service/memory_merge.py`

- [ ] **Step 1: 创建 `memory_merge.py`**

```python
"""记忆合并策略模块"""
from schemas.memory_config import MergeOp


def apply_merge(current_value: str | None, patch_value: str, merge_op: MergeOp) -> str:
    """对字段值应用合并策略。

    Args:
        current_value: 当前字段值（None 表示新字段）
        patch_value: LLM 输出的新值
        merge_op: 合并策略

    Returns:
        合并后的字段值
    """
    if merge_op == MergeOp.REPLACE or current_value is None:
        return patch_value

    if merge_op == MergeOp.IMMUTABLE:
        return current_value

    if merge_op == MergeOp.SUM:
        if current_value:
            return current_value + "\n" + patch_value
        return patch_value

    if merge_op == MergeOp.PATCH:
        # SEARCH/REPLACE 文本替换
        # LLM 输出格式: "SEARCH: <旧文本>\nREPLACE: <新文本>"
        # 多个块用 "---" 分隔
        blocks = patch_value.split("---")
        result = current_value
        for block in blocks:
            block = block.strip()
            if not block:
                continue
            if "SEARCH:" in block and "REPLACE:" in block:
                parts = block.split("REPLACE:", 1)
                search = parts[0].replace("SEARCH:", "").strip()
                replace = parts[1].strip()
                if search in result:
                    result = result.replace(search, replace)
                else:
                    # search 不匹配时追加到末尾
                    result = result + "\n" + replace
            else:
                # 非标准格式，直接追加
                if result and block not in result:
                    result = result + "\n" + block
        return result

    return patch_value
```

- [ ] **Step 2: 单元测试验证**

```bash
cd backend && python -c "
from service.memory_merge import apply_merge
from schemas.memory_config import MergeOp

# Test replace
assert apply_merge('old', 'new', MergeOp.REPLACE) == 'new'

# Test immutable
assert apply_merge('old', 'new', MergeOp.IMMUTABLE) == 'old'

# Test sum
assert apply_merge('line1', 'line2', MergeOp.SUM) == 'line1\nline2'

# Test patch
current = '新能源汽车市占率约35%'
patch = 'SEARCH: 35%\nREPLACE: 42%'
result = apply_merge(current, patch, MergeOp.PATCH)
assert '42%' in result, f'Expected 42% in result, got: {result}'

# Test patch with new field
result = apply_merge(None, 'new', MergeOp.PATCH)
assert result == 'new'

print('All tests passed')
"
```

---

### Task 5: 创建 memory_type_registry.py — YAML Schema 加载器

**Files:**
- Create: `backend/app/service/memory_type_registry.py`

- [ ] **Step 1: 创建 `memory_type_registry.py`**

```python
"""记忆类型注册表 - 加载 YAML 配置"""
import os
from pathlib import Path
from typing import Optional

import yaml

from schemas.memory_config import MemoryTypeSchema, MemoryField, MergeOp, FieldType


class MemoryTypeRegistry:
    """记忆类型注册表，从 YAML 文件加载 schema 配置。"""

    def __init__(self, config_dir: str | None = None):
        self._types: dict[str, MemoryTypeSchema] = {}
        if config_dir is None:
            config_dir = os.path.join(
                os.path.dirname(os.path.dirname(__file__)),
                "app", "config", "memory_types"
            )
        self._config_dir = config_dir
        self._load_all()

    def _load_all(self) -> None:
        """扫描配置目录，加载所有 .yaml 文件。"""
        dir_path = Path(self._config_dir)
        if not dir_path.exists():
            print(f"[MemoryTypeRegistry] 配置目录不存在: {self._config_dir}")
            return

        for yaml_file in sorted(dir_path.glob("*.yaml")):
            try:
                self._load_file(str(yaml_file))
                print(f"[MemoryTypeRegistry] 已加载: {yaml_file.name}")
            except Exception as e:
                print(f"[MemoryTypeRegistry] 加载失败 {yaml_file.name}: {e}")

    def _load_file(self, file_path: str) -> None:
        with open(file_path, "r", encoding="utf-8") as f:
            data = yaml.safe_load(f)

        fields = []
        for fd in data.get("fields", []):
            fields.append(MemoryField(
                name=fd["name"],
                type=FieldType(fd.get("type", "string")),
                description=fd.get("description", ""),
                merge_op=MergeOp(fd.get("merge_op", "patch")),
            ))

        schema = MemoryTypeSchema(
            memory_type=data["memory_type"],
            description=data.get("description", ""),
            directory=data.get("directory", ""),
            filename_template=data.get("filename_template", ""),
            embedding_template=data.get("embedding_template", ""),
            fields=fields,
        )
        self._types[schema.memory_type] = schema

    def get(self, name: str) -> Optional[MemoryTypeSchema]:
        """按名称获取 schema。"""
        return self._types.get(name)

    def list_all(self) -> list[MemoryTypeSchema]:
        """获取所有已注册的记忆类型。"""
        return list(self._types.values())

    def list_names(self) -> list[str]:
        """获取所有记忆类型名称。"""
        return list(self._types.keys())


# 单例
_registry: Optional[MemoryTypeRegistry] = None


def get_memory_type_registry() -> MemoryTypeRegistry:
    global _registry
    if _registry is None:
        _registry = MemoryTypeRegistry()
    return _registry
```

- [ ] **Step 2: 验证加载**

```bash
cd backend && python -c "
from service.memory_type_registry import get_memory_type_registry
registry = get_memory_type_registry()
print('已加载类型:', registry.list_names())
for t in registry.list_all():
    print(f'  {t.memory_type}: {len(t.fields)} 个字段, embedding_template={t.embedding_template[:40]}...')
"
```

预期输出:
```
已加载类型: ['industry_entity', 'research_finding']
  industry_entity: 5 个字段, embedding_template=实体: {entity_name}...
  research_finding: 5 个字段, embedding_template=研究主题: {topic}...
```

---

### Task 6: 重构 memory_service.py — 新的结构化总结 prompt

**Files:**
- Modify: `backend/app/service/memory_service.py:96-165` (summarize_conversation 方法)

- [ ] **Step 1: 替换 `summarize_conversation` 方法**

删除旧的 `summarize_conversation` 方法（line 96-165），替换为:

```python
def summarize_conversation(self, messages: List[ChatMessage]) -> Dict[str, Any]:
    """
    使用 LLM 按记忆类型结构化总结对话。

    Returns:
        {
            "preferences": {...},           # 用户偏好（保留兼容）
            "memories": [                    # 结构化记忆列表
                {
                    "memory_type": "research_finding",
                    "action": "write",       # write / edit / delete
                    "uri": "",              # edit/delete 时必填
                    "page_id": 1,           # 临时 ID，用于链接引用
                    "fields": {
                        "topic": "新能源汽车市占率",
                        "conclusion": "...",
                        "confidence": "高",
                        "sources": "来源: 乘联会2026Q1报告",
                        "related_entities": "比亚迪, 特斯拉"
                    },
                    "links": [
                        {"to_page_id": 2, "link_type": "derived_from",
                         "description": "基于比亚迪实体数据推导"}
                    ]
                }
            ],
            "topics": ["新能源汽车", "市场分析"]
        }
    """
    conversation_text = "\n".join([
        f"{'用户' if msg.role == 'user' else '助手'}: {msg.content}"
        for msg in messages
    ])

    if len(conversation_text) > 30000:
        conversation_text = conversation_text[:30000] + "\n...(对话过长，已截断)"

    # 获取已注册的记忆类型说明
    from service.memory_type_registry import get_memory_type_registry
    registry = get_memory_type_registry()
    type_descriptions = []
    for schema in registry.list_all():
        fields_desc = "\n".join([
            f"      - {f.name} ({f.merge_op.value}): {f.description}"
            for f in schema.fields
        ])
        type_descriptions.append(
            f"  {schema.memory_type}: {schema.description}\n    字段:\n{fields_desc}"
        )
    types_text = "\n".join(type_descriptions)

    prompt = f"""请分析以下对话，提取可跨会话复用的研究成果和行业实体信息。

对话内容：
{conversation_text}

可用的记忆类型：
{types_text}

操作说明：
- action=write: 新建记忆，不需要 uri
- action=edit: 更新已有记忆，需要提供 uri（使用记忆列表中显示的 uri）
- action=delete: 删除过时或被推翻的记忆，需要提供 uri

链接说明（可选）：
- 每条记忆可包含 links 列表，引用同批次其他记忆的 page_id
- link_type 可选: derived_from（推导自）/ related_to（相关）/ contradicts（矛盾）
- description 简要说明关联原因

字段合并策略：
- immutable: 创建后不可修改（如 topic、entity_name）
- patch: 增量更新 - 用 SEARCH/REPLACE 格式描述变更
- replace: 全量替换
- sum: 追加到末尾

请输出以下 JSON 格式（不要包含```json标记）：
{{
    "preferences": {{
        "interests": ["用户感兴趣的领域"],
        "communication_style": "用户偏好的沟通风格",
        "focus_areas": ["用户关注的重点领域"]
    }},
    "memories": [
        {{
            "memory_type": "research_finding 或 industry_entity",
            "action": "write",
            "uri": "",
            "page_id": 1,
            "fields": {{
                "topic": "研究主题",
                "conclusion": "核心结论",
                "confidence": "高/中/低",
                "sources": "信息来源",
                "related_entities": "相关实体"
            }},
            "links": []
        }}
    ],
    "topics": ["主题标签"]
}}"""

    try:
        response = self.client.chat.completions.create(
            model=self.model,
            messages=[
                {"role": "system", "content": "你是一个专业的行业研究分析助手，擅长从对话中提取可复用的研究成果和行业实体信息。"},
                {"role": "user", "content": prompt}
            ],
            temperature=0.3,
        )

        result_text = response.choices[0].message.content.strip()

        if result_text.startswith("```json"):
            result_text = result_text[7:]
        if result_text.startswith("```"):
            result_text = result_text[3:]
        if result_text.endswith("```"):
            result_text = result_text[:-3]

        result = json.loads(result_text.strip())

        # 确保兼容旧格式
        if "memories" not in result:
            result["memories"] = []
        if "preferences" not in result:
            result["preferences"] = {}
        if "topics" not in result:
            result["topics"] = []

        return result

    except Exception as e:
        print(f"总结对话失败: {e}")
        return {
            "preferences": {},
            "memories": [],
            "topics": []
        }
```

- [ ] **Step 2: 验证新 prompt 可正常调用**

需要 DashScope API key 可用。先确认 key 配置:

```bash
cd backend && python -c "
from dotenv import load_dotenv; load_dotenv()
import os; print('API Key configured:', bool(os.getenv('DASHSCOPE_API_KEY')))
"
```

---

### Task 7: 重构 memory_service.py — 新的 create_memory（增量合并 + 三层摘要 + 链接）

**Files:**
- Modify: `backend/app/service/memory_service.py:167-221` (create_memory 方法)
- Modify: `backend/app/service/memory_service.py:223-311` (_store_memory_vectors 方法)

- [ ] **Step 1: 替换 `create_memory` 方法（line 167-221）**

```python
def create_memory(
    self,
    db: Session,
    user_id: str,
    session_id: str,
    messages: List[ChatMessage]
) -> List[LongTermMemory]:
    """
    创建长期记忆 — 支持结构化输出、增量合并和链接解析。

    Args:
        db: 数据库会话
        user_id: 用户ID
        session_id: 会话ID
        messages: 消息列表

    Returns:
        创建/更新的记忆列表
    """
    if not messages:
        return []

    # 1. 结构化总结
    summary_data = self.summarize_conversation(messages)
    memories_data = summary_data.get("memories", [])
    preferences_data = summary_data.get("preferences", {})
    topics_data = summary_data.get("topics", [])

    total_tokens = sum(self.estimate_tokens(msg.content) for msg in messages)
    created_memories: List[LongTermMemory] = []

    # 2. page_id → 真实 URI 映射表（用于链接解析）
    page_id_to_uri: dict[int, str] = {}

    # 3. 处理每条结构化记忆
    for mem_data in memories_data:
        memory_type = mem_data.get("memory_type", "")
        action = mem_data.get("action", "write")
        fields = mem_data.get("fields", {})
        page_id = mem_data.get("page_id", 0)
        uri = mem_data.get("uri", "")
        links = mem_data.get("links", [])

        # 获取该类型的 schema
        from service.memory_type_registry import get_memory_type_registry
        registry = get_memory_type_registry()
        schema = registry.get(memory_type)

        if schema is None:
            print(f"未知的记忆类型: {memory_type}，跳过")
            continue

        # 根据 action 处理
        if action == "delete" and uri:
            self._delete_by_uri(db, user_id, uri)
            continue

        if action == "edit" and uri:
            existing = self._find_by_uri(db, user_id, uri)
        else:
            # write: 根据 immutable 字段查找是否已存在
            existing = self._find_existing(db, user_id, memory_type, fields, schema)

        if existing:
            # 增量合并
            existing.fields = self._merge_fields(
                existing.fields or {}, fields, schema
            )
            existing.summary = fields.get("conclusion") or fields.get("key_facts") or existing.summary
            existing.abstract = self._generate_abstract(existing.summary)
            existing.overview = self._generate_overview(memory_type, existing.fields)
            existing.token_count = max(existing.token_count or 0, total_tokens)
            existing.key_insights = {** (existing.key_insights or {}), **preferences_data}
            # 合并链接
            existing.links = self._merge_links(existing.links or [], links, page_id_to_uri)
            db.commit()
            db.refresh(existing)
            created_memories.append(existing)
            if page_id:
                page_id_to_uri[page_id] = str(existing.id)
        else:
            # 新建
            abstract = self._generate_abstract(
                fields.get("conclusion") or fields.get("key_facts") or ""
            )
            overview = self._generate_overview(memory_type, fields)

            memory = LongTermMemory(
                user_id=user_id,
                session_id=session_id,
                memory_type=memory_type,
                summary=fields.get("conclusion") or fields.get("key_facts") or "",
                abstract=abstract,
                overview=overview,
                key_insights=preferences_data,
                fields=fields,
                links=[],
                backlinks=[],
                token_count=total_tokens,
            )
            db.add(memory)
            db.commit()
            db.refresh(memory)
            created_memories.append(memory)
            if page_id:
                page_id_to_uri[page_id] = str(memory.id)

    # 4. 解析链接（替换 page_id 为真实 URI）
    for memory in created_memories:
        if memory.links:
            resolved_links = []
            for link in memory.links:
                to_page_id = link.get("to_page_id")
                if to_page_id and to_page_id in page_id_to_uri:
                    link["to_uri"] = page_id_to_uri[to_page_id]
                    link.pop("to_page_id", None)
                    resolved_links.append(link)
            memory.links = resolved_links
            db.commit()
            # 更新反向链接
            self._update_backlinks(db, str(memory.id), memory.links)

    # 5. 处理 preferences（仅当没有新的结构化记忆时单独存一条）
    if not created_memories and preferences_data:
        memory = LongTermMemory(
            user_id=user_id,
            session_id=session_id,
            memory_type="preference",
            summary=json.dumps(preferences_data, ensure_ascii=False),
            abstract=f"用户偏好: {', '.join(preferences_data.get('interests', []))}",
            overview=f"关注领域: {', '.join(preferences_data.get('focus_areas', []))}",
            key_insights=preferences_data,
            fields=preferences_data,
            links=[],
            backlinks=[],
            token_count=total_tokens,
        )
        db.add(memory)
        db.commit()
        db.refresh(memory)
        created_memories.append(memory)

    # 6. 向量化所有新建/更新的记忆
    for memory in created_memories:
        milvus_ids = self._store_memory_vectors(
            memory_id=str(memory.id),
            user_id=user_id,
            session_id=session_id,
            memory_type=memory.memory_type,
            summary_data={
                "abstract": memory.abstract or "",
                "overview": memory.overview or "",
                "summary": memory.summary or "",
                "topics": topics_data,
            }
        )
        memory.milvus_ids = milvus_ids
        db.commit()

    print(f"创建/更新了 {len(created_memories)} 条长期记忆")
    return created_memories
```

- [ ] **Step 2: 添加辅助方法到 MemoryService 类**

在 `MemoryService` 类中追加以下方法（放在 `create_memory` 之后）:

```python
def _generate_abstract(self, text: str) -> str:
    """从长文本生成 L0 摘要（取前 2-3 句，约 50 字）。"""
    if not text:
        return ""
    # 简单截取: 取前 100 个字符，在句号处截断
    truncated = text[:100]
    last_period = max(truncated.rfind("。"), truncated.rfind("."), truncated.rfind("；"))
    if last_period > 20:
        return truncated[:last_period + 1]
    return truncated

def _generate_overview(self, memory_type: str, fields: dict) -> str:
    """从 fields 生成 L1 概览（约 150 字）。"""
    parts = [f"[{memory_type}]"]
    for key, value in fields.items():
        if key in ("conclusion", "key_facts"):
            parts.append(str(value)[:120])
        elif key in ("entity_name", "topic"):
            parts.append(f"{key}: {value}")
    return " | ".join(parts)

def _merge_fields(
    self, existing_fields: dict, new_fields: dict, schema
) -> dict:
    """按 schema 中定义的 merge_op 合并字段。"""
    from service.memory_merge import apply_merge

    merged = dict(existing_fields)
    for field_def in schema.fields:
        field_name = field_def.name
        if field_name in new_fields:
            current = merged.get(field_name)
            merged[field_name] = apply_merge(current, new_fields[field_name], field_def.merge_op)
    # 保留新字段中 schema 未定义但 LLM 输出的额外字段
    for key, value in new_fields.items():
        if key not in merged:
            merged[key] = value
    return merged

def _find_existing(
    self, db: Session, user_id: str, memory_type: str, fields: dict, schema
) -> Optional[LongTermMemory]:
    """根据 immutable 字段查找已存在的记忆。"""
    immutable_keys = [
        f.name for f in schema.fields
        if f.merge_op.value == "immutable" and f.name in fields
    ]
    for key in immutable_keys:
        # 查询 fields JSONB 中指定 key 值匹配的记录
        existing = db.query(LongTermMemory).filter(
            LongTermMemory.user_id == user_id,
            LongTermMemory.memory_type == memory_type,
            LongTermMemory.fields[key].astext == fields[key]
        ).first()
        if existing:
            return existing
    return None

def _find_by_uri(self, db: Session, user_id: str, uri: str) -> Optional[LongTermMemory]:
    """通过 URI（即 memory id）查找。"""
    try:
        from uuid import UUID
        mem_uuid = UUID(uri)
        return db.query(LongTermMemory).filter(
            LongTermMemory.id == mem_uuid,
            LongTermMemory.user_id == user_id,
        ).first()
    except (ValueError, AttributeError):
        return None

def _delete_by_uri(self, db: Session, user_id: str, uri: str) -> None:
    """删除指定记忆。"""
    memory = self._find_by_uri(db, user_id, uri)
    if memory:
        self.delete_memory(db, str(memory.id), user_id)

def _merge_links(
    self, existing_links: list, new_links: list, page_id_to_uri: dict
) -> list:
    """合并链接列表，按 to_page_id 去重。"""
    merged = list(existing_links)
    seen = {json.dumps(l, sort_keys=True, ensure_ascii=False) for l in merged}
    for link in new_links:
        link_copy = dict(link)
        serialized = json.dumps(link_copy, sort_keys=True, ensure_ascii=False)
        if serialized not in seen:
            merged.append(link_copy)
            seen.add(serialized)
    return merged

def _update_backlinks(self, db: Session, from_id: str, links: list) -> None:
    """更新目标记忆的 backlinks 字段。"""
    for link in links:
        to_uri = link.get("to_uri")
        if not to_uri:
            continue
        try:
            from uuid import UUID
            target = db.query(LongTermMemory).filter(
                LongTermMemory.id == UUID(to_uri)
            ).first()
            if target:
                backlinks = list(target.backlinks or [])
                new_backlink = {
                    "from_uri": from_id,
                    "link_type": link.get("link_type", "related_to"),
                }
                # 去重
                if not any(
                    b.get("from_uri") == from_id
                    for b in backlinks
                ):
                    backlinks.append(new_backlink)
                    target.backlinks = backlinks
                    db.commit()
        except (ValueError, AttributeError):
            pass
```

- [ ] **Step 3: 更新 `_store_memory_vectors` 签名**

替换原有 `_store_memory_vectors` (line 223-311)，增加 `memory_type` 参数，向量化文本使用 embedding_template:

```python
def _store_memory_vectors(
    self,
    memory_id: str,
    user_id: str,
    session_id: str,
    memory_type: str = "preference",
    summary_data: Dict[str, Any] = None,
) -> List[str]:
    """将记忆内容向量化并存储到 Milvus。"""
    from pymilvus import Collection

    if summary_data is None:
        summary_data = {}

    milvus_ids = []
    documents_to_insert = []

    # 用 embedding_template 渲染向量文本（如果 schema 定义了）
    from service.memory_type_registry import get_memory_type_registry
    registry = get_memory_type_registry()
    schema = registry.get(memory_type)

    # 1. L0 abstract 向量
    abstract = summary_data.get("abstract", "")
    if abstract:
        abstract_vector = generate_embedding(abstract)
        if abstract_vector:
            doc_id = f"{memory_id}_abstract"
            documents_to_insert.append({
                "id": doc_id,
                "user_id": user_id,
                "session_id": session_id,
                "memory_type": memory_type,
                "content": abstract[:65535],
                "metadata": json.dumps({"memory_id": memory_id, "level": "abstract"}),
                "vector": abstract_vector
            })
            milvus_ids.append(doc_id)

    # 2. L2 summary 向量（主检索向量）
    summary = summary_data.get("summary", "")
    if summary:
        # 用 embedding_template 渲染（如果有）
        if schema and schema.embedding_template:
            embedding_text = schema.embedding_template
            # 简单模板替换（不用 Jinja2，减少依赖）
            for key in ("topic", "conclusion", "entity_name", "industry", "key_facts"):
                embedding_text = embedding_text.replace(
                    f"{{{key}}}", summary_data.get("fields", {}).get(key, "")
                )
        else:
            embedding_text = summary

        summary_vector = generate_embedding(embedding_text)
        if summary_vector:
            doc_id = f"{memory_id}_summary"
            documents_to_insert.append({
                "id": doc_id,
                "user_id": user_id,
                "session_id": session_id,
                "memory_type": memory_type,
                "content": summary[:65535],
                "metadata": json.dumps({"memory_id": memory_id, "level": "detail"}),
                "vector": summary_vector
            })
            milvus_ids.append(doc_id)

    # 3. Topics 向量
    topics = summary_data.get("topics", [])
    if topics:
        topics_text = "研究主题: " + ", ".join(topics)
        topics_vector = generate_embedding(topics_text)
        if topics_vector:
            doc_id = f"{memory_id}_topics"
            documents_to_insert.append({
                "id": doc_id,
                "user_id": user_id,
                "session_id": session_id,
                "memory_type": memory_type,
                "content": topics_text[:65535],
                "metadata": json.dumps({"memory_id": memory_id, "topics": topics}),
                "vector": topics_vector
            })
            milvus_ids.append(doc_id)

    # 批量插入 Milvus
    if documents_to_insert:
        try:
            collection = Collection(MEMORY_COLLECTION_NAME)
            collection.load()
            ids = [doc["id"] for doc in documents_to_insert]
            user_ids = [doc["user_id"] for doc in documents_to_insert]
            session_ids = [doc["session_id"] for doc in documents_to_insert]
            memory_types = [doc["memory_type"] for doc in documents_to_insert]
            contents = [doc["content"][:65535] for doc in documents_to_insert]
            metadatas = [doc["metadata"][:8192] for doc in documents_to_insert]
            vectors = [doc["vector"] for doc in documents_to_insert]

            data = [ids, user_ids, session_ids, memory_types, contents, metadatas, vectors]
            collection.insert(data)
            collection.flush()
            print(f"成功存储 {len(documents_to_insert)} 条记忆向量")
        except Exception as e:
            print(f"存储记忆向量失败: {e}")

    return milvus_ids
```

---

### Task 8: 重构 memory_service.py — 三层分级检索

**Files:**
- Modify: `backend/app/service/memory_service.py:423-472` (build_memory_context 方法)

- [ ] **Step 1: 替换 `build_memory_context` 方法**

```python
def build_memory_context(
    self,
    user_id: str,
    current_query: str,
    max_memories: int = 5,
    max_tokens: int = 800,
) -> dict:
    """
    构建记忆上下文，用于增强当前对话。三层分级加载。

    Args:
        user_id: 用户ID
        current_query: 当前查询
        max_memories: 最大记忆数量（L1 overview 级别）
        max_tokens: context_text 最大 token 数

    Returns:
        {"context_text": "...", "memory_ids": ["id1", ...]}
    """
    # Step 1: 粗筛 — Milvus 搜索 top-15
    all_results = self.retrieve_memories(user_id, current_query, top_k=15)

    if not all_results:
        return {"context_text": "", "memory_ids": []}

    # Step 2: 去重 + 按 memory_type 分组（每种最多 3 条）
    from collections import defaultdict
    by_type: dict[str, list] = defaultdict(list)
    seen_ids = set()
    for r in all_results:
        mem_id = r.get("metadata", "{}")
        try:
            meta = json.loads(mem_id) if isinstance(mem_id, str) else mem_id
            real_id = meta.get("memory_id", "")
        except (json.JSONDecodeError, TypeError):
            real_id = r.get("id", "").rsplit("_", 1)[0]  # 去掉 _summary/_abstract 后缀

        if real_id in seen_ids:
            continue
        seen_ids.add(real_id)

        mem_type = r.get("memory_type", "preference")
        if len(by_type[mem_type]) < 3:
            by_type[mem_type].append({
                "id": real_id,
                "content": r.get("content", ""),
                "memory_type": mem_type,
                "score": r.get("score", 0),
            })

    # Step 3: 从 DB 加载 L1 overview，构建 context_text
    # 展平并排序
    candidates = []
    for items in by_type.values():
        candidates.extend(items)
    candidates.sort(key=lambda x: x["score"], reverse=True)
    candidates = candidates[:max_memories]

    if not candidates:
        return {"context_text": "", "memory_ids": []}

    # 从 DB 查询 overview
    from models.chat import LongTermMemory
    from uuid import UUID

    context_parts = ["[相关历史研究记忆]"]
    memory_ids = []
    total_chars = 0

    for c in candidates:
        try:
            mem_uuid = UUID(c["id"])
            mem = self._db_query_by_id(mem_uuid)
        except (ValueError, AttributeError):
            mem = None

        if mem and mem.overview:
            overview = f"- [{mem.memory_type}] {mem.overview}"
        else:
            overview = f"- [{c['memory_type']}] {c['content'][:120]}"

        # 控制总 token（按 1 token ≈ 3 chars 估算）
        if total_chars + len(overview) > max_tokens * 3:
            break

        context_parts.append(overview)
        memory_ids.append(c["id"])
        total_chars += len(overview)

    context_parts.append("")
    context_text = "\n".join(context_parts)

    return {
        "context_text": context_text,
        "memory_ids": memory_ids,
    }


def _db_query_by_id(self, mem_uuid) -> Optional[Any]:
    """从数据库查询单条记忆（内部方法）。"""
    from core.database import SessionLocal
    db = SessionLocal()
    try:
        return db.query(LongTermMemory).filter(
            LongTermMemory.id == mem_uuid
        ).first()
    finally:
        db.close()
```

- [ ] **Step 2: 更新 `retrieve_memories` 签名兼容新字段**

`retrieve_memories` 无需大改，只需在 `output_fields` 中补充 `abstract`。将第 358 行的 `output_fields` 改为:

```python
output_fields=["id", "session_id", "memory_type", "content", "metadata", "abstract"],
```

---

### Task 9: 更新 memory_router.py — 响应 schema 兼容新字段

**Files:**
- Modify: `backend/app/router/memory_router.py:23-60` (MemoryResponse, MemorySearchResult)
- Modify: `backend/app/router/memory_router.py:64-92` (get_memories 端点)

- [ ] **Step 1: 更新 MemoryResponse schema**

替换第 23-31 行:

```python
class MemoryResponse(BaseModel):
    """记忆响应"""
    id: str = Field(..., description="记忆ID")
    session_id: Optional[str] = Field(None, description="关联会话ID")
    memory_type: str = Field("preference", description="记忆类型")
    summary: str = Field(..., description="记忆摘要 (L2)")
    abstract: Optional[str] = Field(None, description="L0 摘要")
    overview: Optional[str] = Field(None, description="L1 概览")
    key_insights: Optional[dict] = Field(None, description="关键洞察")
    fields: Optional[dict] = Field(None, description="动态字段")
    links: list = Field(default_factory=list, description="正向链接")
    backlinks: list = Field(default_factory=list, description="反向链接")
    token_count: Optional[int] = Field(None, description="Token数量")
    created_at: datetime = Field(..., description="创建时间")

    class Config:
        from_attributes = True
```

- [ ] **Step 2: 更新 get_memories 端点响应构建**

替换第 82-90 行的 MemoryResponse 构造:

```python
return MemoryListResponse(
    memories=[
        MemoryResponse(
            id=str(mem.id),
            session_id=str(mem.session_id) if mem.session_id else None,
            memory_type=mem.memory_type or "preference",
            summary=mem.summary,
            abstract=mem.abstract,
            overview=mem.overview,
            key_insights=mem.key_insights,
            fields=mem.fields,
            links=mem.links or [],
            backlinks=mem.backlinks or [],
            token_count=mem.token_count,
            created_at=mem.created_at,
        )
        for mem in memories
    ],
    total=total,
)
```

- [ ] **Step 3: 同样更新 get_memory 端点（第 96-129 行）的 MemoryResponse 构造**

```python
return MemoryResponse(
    id=str(memory.id),
    session_id=str(memory.session_id) if memory.session_id else None,
    memory_type=memory.memory_type or "preference",
    summary=memory.summary,
    abstract=memory.abstract,
    overview=memory.overview,
    key_insights=memory.key_insights,
    fields=memory.fields,
    links=memory.links or [],
    backlinks=memory.backlinks or [],
    token_count=memory.token_count,
    created_at=memory.created_at,
)
```

- [ ] **Step 4: 更新 create_memory_from_session 端点（第 196-203 行）适配返回列表**

`create_memory` 现在返回 `List[LongTermMemory]`，更新路由:

```python
# 创建记忆
memory_service = get_memory_service()
memories = memory_service.create_memory(
    db=db,
    user_id=str(current_user.id),
    session_id=str(session_uuid),
    messages=messages
)

if not memories:
    raise HTTPException(
        status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
        detail="创建记忆失败"
    )

# 返回第一条记忆（兼容原接口）
memory = memories[0]
return MemoryResponse(
    id=str(memory.id),
    session_id=str(memory.session_id) if memory.session_id else None,
    memory_type=memory.memory_type or "preference",
    summary=memory.summary,
    abstract=memory.abstract,
    overview=memory.overview,
    key_insights=memory.key_insights,
    fields=memory.fields,
    links=memory.links or [],
    backlinks=memory.backlinks or [],
    token_count=memory.token_count,
    created_at=memory.created_at,
)
```

- [ ] **Step 5: 更新 get_memory_context 端点（第 244-258 行）适配返回 dict**

```python
@router.get("/context/{query}", response_model=dict)
async def get_memory_context(
    query: str,
    current_user: User = Depends(get_current_user_required),
):
    """获取与查询相关的记忆上下文"""
    memory_service = get_memory_service()
    result = memory_service.build_memory_context(
        user_id=str(current_user.id),
        current_query=query,
        max_memories=5,
    )
    return result
```

---

### Task 10: 集成测试 — 端到端验证

**Files:**
- Create: `backend/test/test_memory_v2.py`

- [ ] **Step 1: 创建测试脚本**

```python
"""记忆层 V2 集成测试"""
import sys
import os
sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

from dotenv import load_dotenv
load_dotenv()


def test_registry_loading():
    """测试 1: MemoryTypeRegistry 能正确加载 YAML。"""
    from service.memory_type_registry import get_memory_type_registry
    registry = get_memory_type_registry()
    names = registry.list_names()
    assert "research_finding" in names, f"Expected research_finding in {names}"
    assert "industry_entity" in names, f"Expected industry_entity in {names}"

    finding = registry.get("research_finding")
    assert finding is not None
    assert len(finding.fields) == 5
    assert finding.fields[0].name == "topic"
    assert finding.fields[0].merge_op.value == "immutable"
    print("✅ test_registry_loading passed")


def test_merge_operations():
    """测试 2: 四种合并策略。"""
    from service.memory_merge import apply_merge
    from schemas.memory_config import MergeOp

    # Replace
    assert apply_merge("old", "new", MergeOp.REPLACE) == "new"
    # Immutable
    assert apply_merge("old", "new", MergeOp.IMMUTABLE) == "old"
    # Sum
    assert apply_merge("line1", "line2", MergeOp.SUM) == "line1\nline2"
    # Patch
    result = apply_merge("市占率约35%", "SEARCH: 35%\nREPLACE: 42%", MergeOp.PATCH)
    assert "42%" in result
    # None current
    assert apply_merge(None, "new", MergeOp.PATCH) == "new"
    print("✅ test_merge_operations passed")


def test_build_memory_context_empty():
    """测试 3: 无记忆时 build_memory_context 返回空。"""
    from service.memory_service import get_memory_service
    service = get_memory_service()
    result = service.build_memory_context(
        user_id="nonexistent-user-id",
        current_query="新能源汽车",
    )
    assert isinstance(result, dict)
    assert "context_text" in result
    assert "memory_ids" in result
    assert result["context_text"] == ""
    assert result["memory_ids"] == []
    print("✅ test_build_memory_context_empty passed")


if __name__ == "__main__":
    test_registry_loading()
    test_merge_operations()
    test_build_memory_context_empty()
    print("\n🎉 所有测试通过")
```

- [ ] **Step 2: 运行测试**

```bash
cd backend && python test/test_memory_v2.py
```

预期: 3 个测试全部通过。

- [ ] **Step 3: 手动端到端测试（需要运行中的服务）**

通过 API 调用测试完整流程:

```bash
# 1. 登录获取 token
TOKEN=$(curl -s -X POST http://localhost:8000/api/auth/login \
  -H "Content-Type: application/json" \
  -d '{"username":"test","password":"test"}' | python3 -c "import sys,json; print(json.load(sys.stdin)['access_token'])")

# 2. 从已有会话创建记忆
curl -s -X POST http://localhost:8000/api/memories/create \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $TOKEN" \
  -d '{"session_id": "<your-session-uuid>"}' | python3 -m json.tool

# 3. 检索记忆
curl -s "http://localhost:8000/api/memories/context/新能源汽车?%20市场" \
  -H "Authorization: Bearer $TOKEN" | python3 -m json.tool
```

---

### 总体文件变更清单

| 操作 | 文件 |
|------|------|
| Create | `backend/migrations/001_add_memory_fields.sql` |
| Create | `backend/app/schemas/memory_config.py` |
| Create | `backend/app/config/memory_types/__init__.py` |
| Create | `backend/app/config/memory_types/research_finding.yaml` |
| Create | `backend/app/config/memory_types/industry_entity.yaml` |
| Create | `backend/app/service/memory_merge.py` |
| Create | `backend/app/service/memory_type_registry.py` |
| Create | `backend/test/test_memory_v2.py` |
| Modify | `backend/app/models/chat.py` (LongTermMemory 类新增字段) |
| Modify | `backend/app/service/memory_service.py` (summarize + create + build + vectors) |
| Modify | `backend/app/router/memory_router.py` (schema + 端点适配) |
