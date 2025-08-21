## Code Generation Test
| Task Type | Prompt | GPT-5 | Claude Opus 4.1 |
|-----------|----------------------|------------------|---------------|
| 代码生成 | [Prompt](./prompts-completion.txt) | [Response](./response-gpt5-completion.txt) [HTML](./response-gpt5-completion.html) | [Response](./response-claude41-completion.txt) [HTML](./response-claude41-completion.html) |
| 代码翻译 | Capable, but slower due to deeper reasoning. | **Best-in-class: Maintains context across modules, ideal for large codebases.** | Strong, but less consistent in long-context edits. |
| 生成注释 | Excellent at identifying and resolving subtle bugs, especially with reasoning mode. | Very strong: Surgical precision in pinpointing and fixing issues. | Good, but may over-edit or miss edge cases. |
| 错误分析 | Generates comprehensive test suites with good coverage. | Slightly better at aligning tests with business logic. | Moderate performance. |
| 代码解释 | **High-fidelity HTML/CSS/JS generation; good with design-to-code prompts.** | Competent, but less visually aligned. | Adequate for basic UI tasks. |
| 文档生成 | **High-fidelity HTML/CSS/JS generation; good with design-to-code prompts.** | Competent, but less visually aligned. | Adequate for basic UI tasks. |
| 代码优化 | Strong with REST/GraphQL scaffolding and error handling. | Comparable, with better documentation generation. | Slightly behind in API structure consistency. |
| 交互问答 | **Free-form function calling** | Bash + file editing tools | Same as 4.1 |
| 安全检查 | Superior | Strong | Moderate |
| 生成单测 | Good | **Very High** | High |