# 研讨会指南

> 🌐 语言 / Language: [English](workshop-guide.md) | **中文**

部署和完整上传/查询流程请从整合后的[模块 6：多智能体业务场景操作指南](../../readme_CN.md)开始。
本页保留为简明讲师参考。

## 目标

以简单的 Product Launch Studio 为示例，实践多智能体业务场景，观察 Agent 路由、共享数据、认证、网络和运行时生命周期。
五个 Agent 独立运行并通过 A2A 协作；LangGraph 只在 Orchestrator 内运行。

## 准备

按[模块 README](../../readme_CN.md)准备：本地 PostgreSQL/vector 或可选的 HorizonDB / Azure PostgreSQL Flexible Server、
配置好的 Foundry 通用模型和嵌入部署、本地文件或私有 Azure Blob、数据库迁移和共享 A2A 对等密钥。
浏览器免密访问：任何持有 Chat URL 的人均可访问该部署的数据。
课前验证权限。使用[模块级 sample-data](../../sample-data/) 中的实际 workshop 上传分片，
不使用旧的 `agent-src/sample-data` 合成数据。确认来源使用权限，绝不要未经授权上传客户机密数据。
[清单](../../sample-data/manifest.json)记录了 5 个 Capgemini PDF 分片、5 个 Ryder PDF 分片、
21 个评论 CSV 分片（41,711 行源数据）及 1 个财务 CSV 分片（700 行源数据）。
先上传少量分片，再按问题需要追加其他分片。
不要上传清单，也不要在同一 Session 混用 [raw 原件](../../sample-data/raw/)及其分片。
启动全部五个服务，而不仅是 Chat。逐 Agent 镜像、AKS Sandbox 资源或 ACA Sandbox 设置见
[沙箱部署](sandbox-deployment_CN.md)。本地五进程测试不能证明云端隔离。
在 Linux 上无需本地部署 SDK 的路径见 [Bash/Bicep/ACA CLI 操作指南](cli-deployment_CN.md)：
复用 Module-01 的资源组/区域/存储账户和 Module-04 已有 SandboxGroup，
在该账户中创建私有 `data`，部署所选数据库，在 ACR 构建镜像，
并部署带有界健康检查的五个 Agent。即使部署脚本报告五个进程全部就绪，
也必须完成下面的模型/Blob/业务流程。
根入口 `deploy.sh` 按 storage → models → database → config → images → aca 执行，并推导容器 ARM ID。
models 阶段添加账户级 embedding 部署及校验 Module-01 UAMI 的 APIM 操作/后端，
不改变已有推理角色，也不创建 IAM 角色分配。
ACA 阶段确保此 UAMI 已分配给组；五个 Agent 均继承它，并在激活前检查令牌获取。
`--stage storage` 直接重试增量管理面容器预配；
账户/Blob 服务、网络、版本控制和 RBAC 保持不变，不删除数据。

默认 `DB_PROVIDER=horizondb`，或设置 `DB_PROVIDER=postgresql`；
用 `deploy-database.sh` 部署所选后端，五个 Agent 必须使用一致的通用 `DB_*` 设置。
两者共享 psycopg 仓储和迁移，默认 `postgres` 数据库，业务/A2A/模型逻辑不变。
不会在区域/容量失败时自动换后端。应针对实际目标部署验证所选提供程序；
一个提供程序的结果不能证明另一个也已通过验收。

## 演示步骤

1. 从自动加载的下拉列表选择 **Session**，或通过 **New session** 创建，然后点击 **Connect**，无需密钥。
   Session 是持久化工作区在界面中的名称：重新连接保留其数据。查询限定于所选 Session，
   但所有 Session 都是共享且可选择的，不构成逐用户访问隔离。
2. 上传 [Capgemini 首个 PDF 分片](../../sample-data/01_capgemini_consumer_trends_2025-pages-000001-000020.pdf)
   和 [Ryder 首个 PDF 分片](../../sample-data/02_ryder_ecommerce_consumer_study_2025-pages-000001-000020.pdf)，
   观察提取、嵌入和存储进度。需要更广覆盖时再追加其他报告分片。
3. 上传[首个评论 CSV 分片](../../sample-data/03_customer_reviews-rows-000001-002000.csv)，
   观察关系型行和关联嵌入。全量评论统计要求所有相关分片处理完成，
   并用 SQL 汇总这些数据集表，而不是统计向量数。
4. 上传[财务 CSV 分片](../../sample-data/04_financial_sample-rows-000001-000700.csv)，
   观察关系型行和零个嵌入，并按处理报告核对接受的行数。
5. 提问 “Write three taglines for a repairable speaker.”，预期 DIRECT，不执行检索。
6. 提问 “According to the uploaded reports, what matters to consumers?”，预期 RAG 和来源证据。
7. 提问 “Which country generated the highest total profit?”，预期对已上传财务数据集执行只读 SQL，
   按国家汇总利润并降序排列。须与实际 CSV 核对，不使用合成测试夹具的固定总额。
8. 提问 “Combine consumer trends and sales performance and recommend the best launch market.”，
   预期 HYBRID、并行工作 Agent 进度、精确结果和明确标注的建议。
9. 询问不存在的话题，预期提示证据不足，而非编造引用。
10. 重启服务。来源、数据集和已完成运行记录保留，运行中任务不会恢复。
11. 停止 SQL 服务并重复 HYBRID，预期明确的部分成功/错误状态，绝不编造 SQL 结果。
12. 检查经过认证的 Agent Card，将每个对等端点映射到自己的沙箱/镜像。

## 故障排除

- `no encryption`：设置 `DB_SSL_MODE=require`，或配置信任后使用 verify-full。
- 缺少向量：验证嵌入部署端点、认证作用域和维度。
- APIM 404：重跑 Module-06 `--stage models` 部署 `/foundry/openai/v1/embeddings`，然后重新生成配置。
  不要绕过网关。401 时检查 Agent UAMI `oid` 和 `ai.azure.com` 调用者 scope；
  后端认证使用 APIM 已获授权的系统身份。
- SQL 被拒绝：支持的函数/表允许列表有意保持较窄范围。
- 无文本：使用文本 PDF，而不是扫描件。
- 分块过多：减小上传大小，或课前配置合理上限。
- 证据薄弱：检查来源和阈值，不要只为强行生成答案而降低阈值。
- 启动时数据库失败：检查网络/DNS、TLS、凭据和迁移。
- A2A 401：使用独立且匹配的对等密钥，绝不要输入浏览器。
- INVALID_AGENT_CARD：验证公网 URL、角色、预期技能和协议版本，不要禁用验证。
- PEER_UNAVAILABLE：检查沙箱状态、端口、网络、DNS 和凭据；本示例不会自动恢复沙箱。
- Docker Desktop 无法启动：这影响可选本地容器执行，不影响 ACR 镜像构建。
  使用[部署指南](sandbox-deployment_CN.md)中的 Bash/PowerShell ACR Tasks 脚本远程构建镜像。
- ACR 构建失败：检查 Azure CLI 运行日志、注册表权限、注册表构建容量和云端构建器访问依赖的能力。
  此前本地 `files.pythonhosted.org` TLS 失败不能证明 ACR 存在同样问题。
  不要禁用证书验证或使用不可信包镜像源。
- Compose 拒绝 `ACR_LOGIN_SERVER`：在 `.env` 中设置已有注册表登录服务器主机名和已构建的
  `IMAGE_TAG`，完成镜像拉取认证并拉取 ACR 构建的镜像，不要在本地构建。

停止服务并遵循[安全清理说明](security_CN.md#清理)。
分别检查本地和 Azure 成本：Agent 空闲不代表数据库已经缩容至零。
