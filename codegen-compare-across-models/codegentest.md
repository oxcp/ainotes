## Code Generation Test
**以下分别针对不同的使用场景，使用完全相同的提示词，测试GPT5和Claude Opus 4.1在开发相关各项任务中的表现：** 
| Task Type | Prompt | Azure OpenAI GPT5 | Claude Opus 4.1 |
|-----------|----------------------|------------------|---------------|
| 代码生成 | [Prompt](./prompts/prompts-completion.yaml) | [Response](./output/response-gpt5-completion.txt) | [Response](./output/response-claude-opus-4-1-20250805-completion.txt) |
| 智能问答 | [Prompt](./prompts/prompts-QnA.yaml) | [Response](./output/response-gpt5-QnA.txt) | [Response](./output/response-claude-opus-4-1-20250805-QnA.txt) |
| 解释代码 | [Prompt](./prompts/prompts-explain.yaml) | [Response](./output/response-gpt5-explain.txt) | [Response](./output/response-claude-opus-4-1-20250805-explain.txt) |
| 报错分析 | [Prompt](./prompts/prompts-erranalysis.yaml) | [Response](./output/response-gpt5-erranalysis.txt) | [Response](./output/response-claude-opus-4-1-20250805-erranalysis.txt) |
| 优化代码 | [Prompt](./prompts/prompts-optimization.yaml) | [Response](./output/response-gpt5-optimization.txt) | [Response](./output/response-claude-opus-4-1-20250805-optimization.txt) |
| 生成单测 | [Prompt](./prompts/prompts-unittestcase.yaml) | [Response](./output/response-gpt5-unittestcase.txt) | [Response](./output/response-claude-opus-4-1-20250805-unittestcase.txt) |
| 代码注释 | [Prompt](./prompts/prompts-codecomments.yaml) | [Response](./output/response-gpt5-codecomments.txt) | [Response](./output/response-claude-opus-4-1-20250805-codecomments.txt) |
| 文档生成 | [Prompt](./prompts/prompts-generatedoc.yaml) | [Response](./output/response-gpt5-generatedoc.txt) | [Response](./output/response-claude-opus-4-1-20250805-generatedoc.txt) |
| 代码翻译 | [Prompt](./prompts/prompts-codetranslation.yaml) | [Response](./output/response-gpt5-codetranslation.txt) | [Response](./output/response-claude-opus-4-1-20250805-codetranslation.txt) |
| 安全检查 | [Prompt](./prompts/prompts-securitycheck.yaml) | [Response](./output/response-gpt5-securitycheck.txt) | [Response](./output/response-claude-opus-4-1-20250805-securitycheck.txt) |
