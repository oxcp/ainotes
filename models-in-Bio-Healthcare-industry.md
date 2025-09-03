## Model Comparison

| 对比项         | [GPT-5](https://openai.com/index/introducing-gpt-5/)          | [Stanford-BiomedLM](https://huggingface.co/stanford-crfm/BioMedLM)           | [LLaMA3-Med42 (v2)](https://huggingface.co/m42-health/Llama3-Med42-70B)         | [TxAgent-T1](https://huggingface.co/mims-harvard/TxAgent-T1-Llama-3.1-8B)                  | [BioGPT 系列](https://huggingface.co/microsoft/biogpt)                   | [BioMistral-7B](https://huggingface.co/BioMistral/BioMistral-7B)                |
|---------------|------------|-----------------|---------------------------|-----------------------------|-------------------------------|------------------------------|
| 开发机构       | OpenAI                     | Stanford CRFM + MosaicML    | M42 Health                | 哈佛 MIMS 实验室            | 微软研究院                    | 法国学术与医疗机构合作        |
| 模型架构       | 多模态统一架构（文本、图像、结构化数据） | 类 GPT-2                    | 基于 LLaMA 3              | 治疗性推理智能体：LLaMA 3.1 + 工具调用         | 基于 GPT-2 预训练, Transformer 架构              | 基于 Mistral 预训练                |
| 参数规模       | 超过500B | 2.7B                        | 8B / 70B                  | 8B                      | Base / Large                  | 7B                           |
| 训练数据       | 多语言医学考试题、图像、结构化数据（如 MedQA、MMLU-Medical、VQA-RAD 等）  | PubMed 摘要、The Pile       | 医学题库、考试题、对话数据 | TxAgent-Instruct 数据集      | 1500 万篇 PubMed 摘要         | PubMed Central 开放获取数据   |
| 性能表现       | 在 MedQA、MMLU-Medical、VQA-RAD 等多模态医学任务中全面超越 GPT-4   | MedQA 准确率 50.3%           | MedQA 准确率 79.1%（70B）  | 药物推理任务准确率 92.1%     | PubMedQA：78.2%（Base），81.0%（Large） | 10 个医学问答基准上表现优异   |
| 主要应用场景   | 多模态医学推理、临床决策支持、健康素养提升、文献综述、假设生成   | 生物医学问答、文本生成       | 医学问答、病历摘要、临床决策支持、健康问答 | 药物相互作用分析、禁忌检测、个性化治疗 | 生物医学文本生成、问答、关系抽取 | 医学问答、多语言生物医学 NLP  |
| 限制说明       | 不替代专业医生；用于辅助理解和决策   | 仅限研究使用，不能用于临床   | 尚未临床验证，仍在人工评估中 | 研究用途。依赖工具调用因此受限于工具能力          | 仅供研究使用，非临床用途       | 仅限研究使用，尚未临床验证    |
| 许可证         | Azure OpenAI / OpenAI 提供API访问  | BigScience BLOOM RAIL-1.0      | LLaMA 3 社区许可证         | MIT License                       | MIT License                        | apache-2.0                       |

### Reference
- [OpenAI GPT-5](https://openai.com/index/introducing-gpt-5/)
- [Stanford-BiomedLM](https://crfm.stanford.edu/2022/12/15/biomedlm.html)
- [LLaMA3-Med42](https://ollama.com/thewindmom/llama3-med42-70b)
- [TxAgent-T1, ](https://github.com/mims-harvard/TxAgent) [[blog]](https://kempnerinstitute.harvard.edu/research/deeper-learning/txagent-an-ai-agent-for-therapeutic-reasoning-across-a-universe-of-211-tools/)
- [BioGPT](https://github.com/microsoft/BioGPT)
- [BioMistral-7B](https://github.com/BioMistral/BioMistral?tab=readme-ov-file)

## Have these models obtained, or are they in the process of obtaining, FDA approval in the United States?

| 模型名称            | FDA 审批状态 | 备注说明
|---------------------|--------------|--------------------------------------------------------------------------|
| [RAD-DINO](https://huggingface.co/microsoft/rad-dino)            | ❌未获批准     | 在 FDA 数据库中未找到相关记录|
| [ToolRAG-T1](https://huggingface.co/mims-harvard/ToolRAG-T1-GTE-Qwen2-1.5B)         | ❌未获批准     | 在 FDA 数据库中未找到相关记录|
| [MedImageInsight](https://huggingface.co/lion-ai/MedImageInsights)     | ❌未获批准     | 微软官方说明仅用于研究，非临床用途 [Link](https://learn.microsoft.com/en-us/azure/ai-foundry/how-to/healthcare-ai/deploy-medimageinsight)|
| [LLaVA-Med](https://huggingface.co/microsoft/llava-med-v1.5-mistral-7b)           | ❌未获批准     | Hugging Face 模型卡明确指出不适用于临床 |
| [CXRReportGen](https://aka.ms/CXRReportGenModelCard)        | ❌未获批准     | 微软官方说明仅用于研究，非临床用途 [Link](https://learn.microsoft.com/en-us/azure/ai-foundry/how-to/healthcare-ai/deploy-cxrreportgen)|
| [BaichuanMed-OCR](https://huggingface.co/baichuan-inc/BaichuanMed-OCR-7B)     | ❌未获批准     | 在 FDA 数据库中未找到相关记录，模型用于研究 |
| [Virchow](https://huggingface.co/paige-ai/Virchow2)             | ❌未获批准     | Paige基于Virchow开发AI产品，是首家获得FDA批准的在数字病理领域应用临床人工智能的公司，但 FDA 数据库中含Virchow keywords的相关记录和模型无关 [Link](https://www.businesswire.com/news/home/20240108657644/en/Paige-Unveils-Game-Changing-AI-That-Revolutionizes-Cancer-Detection-Across-Multiple-Tissue-Types)|
| [Prov-GigaPath](https://huggingface.co/prov-gigapath/prov-gigapath)       | ❌未获批准     | 在 FDA 数据库中未找到相关记录，仅供学术使用 [Link](https://www.pathologynews.com/digital-pathology/prov-gigapath-microsofts-ai-model-analyzes-gigapixel-pathology-slides-2/)|
| MedSAM2            | ❌未获批准     | 在 FDA 数据库中未找到相关记录，仅见于学术论文 [Link](https://arxiv.org/html/2409.04298v1)|
| MedImageParse      | ❌未获批准     | 微软官方说明仅用于研究，非临床用途 [Link](https://learn.microsoft.com/en-us/azure/ai-foundry/how-to/healthcare-ai/deploy-medimageparse)|

**FDA database**: https://www.fda.gov/ （搜索关键词：模型名称）