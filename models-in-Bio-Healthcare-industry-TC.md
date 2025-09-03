## Model Comparison

| 對比項         | [GPT-5](https://openai.com/index/introducing-gpt-5/)          | [Stanford-BiomedLM](https://huggingface.co/stanford-crfm/BioMedLM)           | [LLaMA3-Med42 (v2)](https://huggingface.co/m42-health/Llama3-Med42-70B)         | [TxAgent-T1](https://huggingface.co/mims-harvard/TxAgent-T1-Llama-3.1-8B)                  | [BioGPT 系列](https://huggingface.co/microsoft/biogpt)                   | [BioMistral-7B](https://huggingface.co/BioMistral/BioMistral-7B)                |
|---------------|------------|-----------------|---------------------------|-----------------------------|-------------------------------|------------------------------|
| 開發機構       | OpenAI                     | Stanford CRFM + MosaicML    | M42 Health                | 哈佛 MIMS 實驗室            | 微軟研究院                    | 法國學術與醫療機構合作        |
| 模型架構       | 多模態統一架構（文本、圖像、結構化數據） | 類 GPT-2                    | 基於 LLaMA 3              | 治療性推理智能體：LLaMA 3.1 + 工具調用         | 基於 GPT-2 預訓練, Transformer 架構              | 基於 Mistral 預訓練                |
| 參數規模       | 超過500B | 2.7B                        | 8B / 70B                  | 8B                      | Base / Large                  | 7B                           |
| 訓練數據       | 多語言醫學考試題、圖像、結構化數據（如 MedQA、MMLU-Medical、VQA-RAD 等）  | PubMed 摘要、The Pile       | 醫學題庫、考試題、對話數據 | TxAgent-Instruct 數據集      | 1500 萬篇 PubMed 摘要         | PubMed Central 開放獲取數據   |
| 性能表現       | 在 MedQA、MMLU-Medical、VQA-RAD 等多模態醫學任務中全面超越 GPT-4   | MedQA 準確率 50.3%           | MedQA 準確率 79.1%（70B）  | 藥物推理任務準確率 92.1%     | PubMedQA：78.2%（Base），81.0%（Large） | 10 個醫學問答基準上表現優異   |
| 主要應用場景   | 多模態醫學推理、臨床決策支持、健康素養提升、文獻綜述   | 生物醫學問答、文本生成       | 醫學問答、病歷摘要、臨床決策支持、健康問答 | 藥物相互作用分析、禁忌檢測、個性化治療 | 生物醫學文本生成、問答、關係抽取 | 醫學問答、多語言生物醫學 NLP  |
| 限制說明       | 不替代專業醫生；用於輔助理解和決策   | 僅限研究使用，不能用於臨床   | 尚未臨床驗證，仍在人工評估中 | 研究用途。依賴工具調用因此受限於工具能力          | 僅供研究使用，非臨床用途       | 僅限研究使用，尚未臨床驗證    |
| 許可證         | Azure OpenAI / OpenAI 提供API訪問  | BigScience BLOOM RAIL-1.0      | LLaMA 3 社區許可證         | MIT License                       | MIT License                        | apache-2.0                       |

### Reference
- [OpenAI GPT-5](https://openai.com/index/introducing-gpt-5/)
- [Stanford-BiomedLM](https://crfm.stanford.edu/2022/12/15/biomedlm.html)
- [LLaMA3-Med42](https://ollama.com/thewindmom/llama3-med42-70b)
- [TxAgent-T1, ](https://github.com/mims-harvard/TxAgent) [[blog]](https://kempnerinstitute.harvard.edu/research/deeper-learning/txagent-an-ai-agent-for-therapeutic-reasoning-across-a-universe-of-211-tools/)
- [BioGPT](https://github.com/microsoft/BioGPT)
- [BioMistral-7B](https://github.com/BioMistral/BioMistral?tab=readme-ov-file)

## 這些模型是否已獲得或正在美國獲得 FDA 批准？

| 模型名稱            | FDA 審批狀態 | 備註說明
|---------------------|--------------|--------------------------------------------------------------------------|
| [RAD-DINO](https://huggingface.co/microsoft/rad-dino)            | ❌未獲批准     | 在 FDA 資料庫中未找到相關記錄|
| [ToolRAG-T1](https://huggingface.co/mims-harvard/ToolRAG-T1-GTE-Qwen2-1.5B)         | ❌未獲批准     | 在 FDA 資料庫中未找到相關記錄|
| [MedImageInsight](https://huggingface.co/lion-ai/MedImageInsights)     | ❌未獲批准     | 微軟官方說明僅用於研究，非臨床用途 [Link](https://learn.microsoft.com/en-us/azure/ai-foundry/how-to/healthcare-ai/deploy-medimageinsight)|
| [LLaVA-Med](https://huggingface.co/microsoft/llava-med-v1.5-mistral-7b)           | ❌未獲批准     | Hugging Face 模型卡明確指出不適用於臨床 |
| [CXRReportGen](https://aka.ms/CXRReportGenModelCard)        | ❌未獲批准     | 微軟官方說明僅用於研究，非臨床用途 [Link](https://learn.microsoft.com/en-us/azure/ai-foundry/how-to/healthcare-ai/deploy-cxrreportgen)|
| [BaichuanMed-OCR](https://huggingface.co/baichuan-inc/BaichuanMed-OCR-7B)     | ❌未獲批准     | 在 FDA 資料庫中未找到相關記錄，模型用於研究 |
| [Virchow](https://huggingface.co/paige-ai/Virchow2)             | ❌未獲批准     | Paige基於Virchow開發AI產品，是首家獲得FDA批准的在數位病理領域應用臨床人工智慧的公司，但 FDA 資料庫中含Virchow keywords的相關記錄和模型無關 [Link](https://www.businesswire.com/news/home/20240108657644/en/Paige-Unveils-Game-Changing-AI-That-Revolutionizes-Cancer-Detection-Across-Multiple-Tissue-Types)|
| [Prov-GigaPath](https://huggingface.co/prov-gigapath/prov-gigapath)       | ❌未獲批准     | 在 FDA 資料庫中未找到相關記錄，僅供學術使用 [Link](https://www.pathologynews.com/digital-pathology/prov-gigapath-microsofts-ai-model-analyzes-gigapixel-pathology-slides-2/)|
| MedSAM2            | ❌未獲批准     | 在 FDA 資料庫中未找到相關記錄，僅見於學術論文 [Link](https://arxiv.org/html/2409.04298v1)|
| MedImageParse      | ❌未獲批准     | 微軟官方說明僅用於研究，非臨床用途 [Link](https://learn.microsoft.com/en-us/azure/ai-foundry/how-to/healthcare-ai/deploy-medimageparse)|

**FDA database**: https://www.fda.gov/ （搜尋關鍵詞：模型名稱