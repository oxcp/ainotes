## Model Comparison

| 对比项         | GPT-5          | Stanford-BiomedLM           | LLaMA3-Med42 (v2)         | TxAgent-T1                  | BioGPT 系列                   | BioMistral-7B                |
|---------------|------------|-----------------|---------------------------|-----------------------------|-------------------------------|------------------------------|
| 开发机构       | OpenAI                     | Stanford CRFM + MosaicML    | M42 Health                | 哈佛 MIMS 实验室            | 微软研究院                    | 法国学术与医疗机构合作        |
| 模型架构       | 多模态统一架构（文本、图像、结构化数据） | 类 GPT-2                    | 基于 LLaMA 3              | LLaMA 3.1 + 工具调用         | Transformer 架构              | 基于 Mistral                 |
| 参数规模       | 未公开（优化为高质量推理） | 2.7B                        | 8B / 70B                  | 未公开                      | Base / Large                  | 7B                           |
| 训练数据       | 多语言医学考试题、图像、结构化数据（如 MedQA、MMLU-Medical、VQA-RAD 等）  | PubMed 摘要、The Pile       | 医学题库、考试题、对话数据 | TxAgent-Instruct 数据集      | 1500 万篇 PubMed 摘要         | PubMed Central 开放获取数据   |
| 性能表现       | 在 MedQA、MMLU-Medical、VQA-RAD 等多模态医学任务中全面超越 GPT-4   | MedQA 准确率 50.3%           | MedQA 准确率 79.1%（70B）  | 药物推理任务准确率 92.1%     | PubMedQA：78.2%（Base），81.0%（Large） | 10 个医学问答基准上表现优异   |
| 主要应用场景   | 多模态医学推理、临床决策支持、健康素养提升、文献综述、假设生成   | 生物医学问答、文本生成       | 医学问答、病历摘要、临床决策支持 | 药物相互作用分析、禁忌检测、个性化治疗 | 生物医学文本生成、问答、关系抽取 | 医学问答、多语言生物医学 NLP  |
| 限制说明       | 非医疗器械，不替代专业医生；用于辅助理解和决策   | 仅限研究使用，不能用于临床   | 尚未临床验证，仍在人工评估中 | 需高端硬件，研究用途          | 仅供研究使用，非临床用途       | 仅限研究使用，尚未临床验证    |
| 许可证         | OpenAI 专有（API 访问）  | BigScience BLOOM RAIL       | LLaMA 3 社区许可证         | 未公开                       | 未公开                        | 未公开                       |


## Have these models obtained, or are they in the process of obtaining, FDA approval in the United States?

| Model            | FDA Status | Details                                                                                                                                                                                                 |
|------------------|------------|---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| Virchow          | ✅ Approved | Developed by Paige, Virchow is the first AI foundation model for digital pathology to receive FDA approval for clinical use in cancer detection. [Major Study](https://www.paige.ai/press-releases/2023-03-15-paige-announces-fda-approval-for-virchow-ai-foundation-model-for-digital-pathology) |
| RAD-DINO         | ❌ Not approved | Microsoft Health Futures explicitly states it is for research only and not intended for clinical use. [microsoft/...gging Face](https://huggingface.co/microsoft/rad-dino) |
| ToolRAG-T1      | ❌ Not approved | No FDA filings found; described as a research model for therapeutic reasoning. [mims-harva...gging Face](https://huggingface.co/mims-harvard/ToolRAG-T1-GTE-Qwen2-1.5B) |
| MedImageInsight  | ❌ Not approved | Microsoft documentation clearly states it is not intended for clinical deployment. [How to dep...ure AI ...](https://learn.microsoft.com/en-us/azure/ai-foundry/how-to/healthcare-ai/deploy-medimageinsight) |
| LLaVA-Med       | ❌ Not approved | Hugging Face model card states it is not suitable for clinical settings. [microsoft/...gging Face](https://huggingface.co/microsoft/llava-med-v1.5-mistral-7b) |
| CXRReportGen     | ❌ Not approved | Microsoft documentation states it is for research and development only. [How to dep...ure AI ...](https://learn.microsoft.com/en-us/azure/ai-foundry/how-to/healthcare-ai/deploy-cxrreportgen) |
| BaichuanMed-OCR  | ❌ Not approved | No FDA filings found; model is open-source and intended for research. [baichuan-i...gging Face](https://huggingface.co/baichuan-inc/BaichuanMed-OCR-7B) |
| Prov-GigaPath    | ❌ Not approved | Developed by Microsoft and Providence; currently used in research and not FDA-cleared. [Prov-GigaP...ogy Slides](https://www.pathologynews.com/digital-pathology/prov-gigapath-microsofts-ai-model-analyzes-gigapixel-pathology-slides-2/) |
| MedSAM2          | ❌ Not approved | No FDA filings found; research model for medical image segmentation. [FS-MedSAM2...Image ...](https://arxiv.org/html/2409.04298v1) |
| MedImageParse    | ❌ Not approved | Microsoft documentation states it is not intended for clinical use. [MedImagePa...ure AI ...](https://learn.microsoft.com/en-us/azure/ai-foundry/how-to/healthcare-ai/deploy-medimageparse) |