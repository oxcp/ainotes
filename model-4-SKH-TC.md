## 模型技術架構與技術參考

| 模型名稱              | 技術架構/方法                                      | 相關論文/文件                                                         |
|----------------------|----------------------------------------------------|-----------------------------------------------------------------------|
| Virchow FAMILY       | Vision Transformer (ViT-H)，自我監督學習（DINOv2）    | [Hugging Face Model Card](https://huggingface.co/paige-ai/Virchow2) <br> [Paige 官方Blog](https://www.paige.ai/blog/the-virchow-foundation-model-explained-a-qa-with-an-ai-scientist/) <br> [arXiv:2309.07778](https://arxiv.org/abs/2309.07778) <br> [arXiv:2309.07778 pdf](https://arxiv.org/pdf/2309.07778) <br> [arXiv:2408.00738](https://arxiv.org/abs/2408.00738)                           |
| RAD-DINO             | Vision Transformer，DINOv2自我監督學習                | [Hugging Face Model Card](https://huggingface.co/microsoft/rad-dino) <br> [arXiv:2401.10815](https://arxiv.org/abs/2401.10815) <br> [知乎Blog](https://zhuanlan.zhihu.com/p/24305678785)                           |
| FCDD                 | 全卷積網路（Fully Convolutional Data Description）  | [GitHub / ICLR 2021 Paper](https://github.com/liznerski/fcdd) <br> [arXiv:2206.02598](https://arxiv.org/pdf/2206.02598)                            |
| MedImageParse FAMILY <br>(Azure AI Foundry有提供) | Transformer架構，任務適配層，支援文字提示           | [Microsoft Learn 文件](https://learn.microsoft.com/zh-tw/azure/ai-foundry/how-to/healthcare-ai/deploy-medimageparse)                       |
| PRISM                | 基於Stable Diffusion的生成式模型，語言引導           | [MIDL 2025 會議論文](https://www.familydoctor.cn/news/prism-yizhong-yongyu-yixueyingxiang-kejieshi-chengshi-ai-moxing-121851.html) <br> [Science Bulletin 2024](https://www.x-mol.com/paper/1825036485145468928/t)            |
| PROV-GIGAPATH        | GigaPath架構 + LongNet，ViT-G/14，DINOv2預訓練      | [GitHub](https://github.com/prov-gigapath/prov-gigapath) <br> [Nature 2024](https://zhuanlan.zhihu.com/p/1887815114905846462)                   |
| CXR REPORTGEN <br>(Azure AI Foundry有提供)       | BiomedCLIP影像編碼器 + Phi-3-Mini語言模型           | [Microsoft Learn 文件](https://learn.microsoft.com/zh-tw/azure/ai-foundry/how-to/healthcare-ai/deploy-cxrreportgen)                 |

---

## 模型擅長疾病詳細列表

| 模型名稱            | 擅長識別的疾病/任務                                                                                         |
|--------------------|-------------------------------------------------------------------------------------------------------------|
| Virchow FAMILY     | **常見癌症：** 乳癌、肺癌、前列腺癌、結直腸癌、胃癌、肝癌、膀胱癌、子宮內膜癌、卵巢癌<br>**罕見癌症：** 神經內分泌腫瘤、軟組織肉瘤、胰臟癌、膽管癌、腦腫瘤、骨肉瘤、腎上腺癌<br>**生物標誌物預測：** HER2、ER、PR、TP53、KRAS、EGFR 等 |
| RAD-DINO           | **胸部X光疾病：** 肺炎、肺氣腫、肺不張、肺結節、肺纖維化、氣胸、心臟肥大、主動脈擴張、胸腔積液、胸管、氣管偏移、縱隔增寬、骨折、支氣管炎、結核、腫瘤等 |
| FCDD               | **異常偵測（無特定疾病標籤）：** 偵測影像中與正常分布不符的區域，如腫瘤、病灶、結構異常、藥丸缺陷、FCD II型癲癇病灶等 |
| MedImageParse      | **多模態影像任務：** 支援CT、MRI、X光、病理影像等的分割、偵測、識別<br>**識別對象：** 腦腫瘤、肝臟病變、肺結節、心臟結構、骨折、眼底病變、腎臟病變、乳腺腫塊、前列腺病變等（可透過文字提示控制） |
| PRISM              | **癌症偵測與報告生成：** 乳癌、前列腺癌、胃腸道癌、胰臟癌、肝癌、肺癌、神經內分泌腫瘤、罕見癌症等<br>**任務類型：** 零樣本癌症偵測、病理報告生成、病理問答、多輪診斷對話 |
| PROV-GIGAPATH      | **癌症亞型分類與病理組學任務：** 乳癌、肺癌、結直腸癌、胃癌、肝癌、胰臟癌、前列腺癌、腦腫瘤、骨肉瘤等<br>**任務類型：** 癌症亞型識別、腫瘤微環境分析、生物標誌物預測、視覺-語言對齊 |
| CXR REPORTGEN      | **胸部X光報告生成：** 肺炎、氣胸、心臟肥大、胸腔積液、肺結節、氣管偏移、骨折、支氣管炎、結核、腫瘤等<br>**任務類型：** 定位病灶、生成結構化報告、對比歷史影像 |

**說明與補充**
- Virchow FAMILY 與 PROV-GIGAPATH 是目前最強的病理基礎模型，支援多種癌症偵測與亞型分類。
- RAD-DINO 與 CXR REPORTGEN 專注於胸部X光，前者用於分類與分割，後者用於報告生成。
- FCDD 是無監督異常偵測模型，適用於缺乏標籤的醫學影像。
- MedImageParse 是多模態統一模型，支援透過文字提示識別任意醫學對象。
- PRISM 是唯一支援多輪問答與報告生成的病理模型，強調臨床語言理解。

---

## 醫學影像模型適用人群
| 模型名稱           | 適用人群描述                                   | 是否適用於2歲以下患者 |
|--------------------|-----------------------------------------------|----------------------|
| Virchow FAMILY     | 成人患者，尤其是癌症患者；訓練資料來自10萬+成人患者的病理切片 | ❌ 未明確支援兒童或嬰幼兒病理影像 |
| RAD-DINO           | 成人胸部X光患者；訓練資料來自MIMIC-CXR等成人資料集         | ❌ 未明確支援2歲以下兒童         |
| FCDD               | 通用異常偵測模型，適用於工業與醫學影像；無特定人群限制         | ✅ 可用於兒童影像，但需自訂訓練資料 |
| MedImageParse FAMILY | 多模態醫學影像分析，適用於研究用途；未用於臨床             | ❌ 不建議用於臨床診斷，包括兒童   |
| PRISM              | 成人病理影像生成與解釋；強調可解釋性與反事實生成             | ❌ 未明確支援兒童病理影像         |
| PROV-GIGAPATH      | 成人癌症患者；訓練資料來自30,000+成人患者的病理切片           | ❌ 未明確支援兒童或嬰幼兒         |
| CXR REPORTGEN      | 成人胸部X光報告生成；訓練資料來自MIMIC-CXR等成人資料集         | ❌ 不建議用於兒童，尤其是2歲以下   |

**說明與補充**
- Virchow FAMILY 與 PROV-GIGAPATH 均基於成人病理切片訓練，未在兒童樣本上驗證。
- RAD-DINO 與 CXR REPORTGEN 使用的MIMIC-CXR資料集主要來自成人患者，未包含嬰幼兒。
- FCDD 是唯一可透過自訂訓練資料適配兒童影像的模型，但需自行準備資料。
- MedImageParse 與 PRISM 明確聲明僅用於研究用途，不適用於臨床診斷或兒童患者。

---

## 模型準確性表現
| 模型名稱         | 準確性表現 | 高準確率疾病         | 性能下降條件                  |
|------------------|--------------------|-----------------------|------------------------------|
| Virchow FAMILY   | AUC高達0.95（平均），在乳癌、肺癌、胰臟癌等任務中表現優異 | 肺癌（AUC 0.989）、胰臟癌（AUC 0.983）、乳癌（AUC 0.974） | 在子宮頸癌等罕見癌症中AUC略低（如0.875） |
| RAD-DINO         | 在VinDr-CXR、RSNA-Pneumonia等資料集上表現優異，尤其在氣胸和胸管偵測上超越多模態模型 | 氣胸、胸管、肺炎 | 在心臟肥大、主動脈擴張等任務中略遜於多模態模型 |
| FCDD             | 在MVTec-AD等工業資料集上達到SOTA，在醫學影像中表現依賴於訓練資料品質 | 癲癇病灶、藥丸缺陷等異常偵測 | 對於複雜結構或高雜訊影像，解釋性熱圖可能不穩定 |
| MedImageParse FAMILY | 未公開具體準確率，強調多模態統一性與任務適配能力 | 多模態影像分割、偵測、識別 | 不適用於臨床，性能依賴提示品質與影像模態 |
| PRISM            | 在零樣本癌症偵測中AUC達0.952，報告生成品質接近專家水準 | 罕見癌症、乳癌、前列腺癌 | 對於低品質影像或文字提示不明確時性能下降 |
| PROV-GIGAPATH    | 在26項任務中25項達SOTA，尤其在癌症亞型分類與病理組學任務中表現突出 | 乳癌、肺癌、結直腸癌等 | 對於極端稀有病理類型或低品質切片，性能可能下降 |
| CXR REPORTGEN    | CheXpert F1-14達59.1，RadGraph-F1達40.8，報告生成品質高 | 肺炎、氣胸、心臟肥大等 | 對於缺乏歷史影像或報告的病例，生成品質下降 |

**說明與補充**
- Virchow FAMILY 與 PROV-GIGAPATH 是目前在病理影像分析中表現最強的基礎模型，適用於多種癌症偵測任務。
- RAD-DINO 在胸部X光分類與分割任務中表現優異，尤其在氣胸等任務中超越多模態模型。
- FCDD 是異常偵測模型，適用於無標籤或少標籤場景，但對影像品質敏感。
- MedImageParse 強調多模態統一性，適用於研究用途，但未公開準確率。
- PRISM 是唯一支援反事實生成與多輪問答的模型，適用於臨床解釋性任務。
- CXR REPORTGEN 在報告生成任務中表現良好，適合用於自動化報告草稿生成。

---

## 模型格式支援
| 模型名稱              | 支援DICOM格式 | 支援單幀/多幀         | 支援非DICOM格式           | 支援的非DICOM格式         |
|----------------------|:-------------:|:---------------------:|:-------------------------:|:--------------------------|
| Virchow FAMILY       | ✅ 支援（透過OpenSlide讀取WSI） | ✅ 多幀（WSI切片）      | ✅ 支援（如SVS、NDPI、TIFF等） | SVS、NDPI、TIFF、PNG（透過OpenSlide） |
| RAD-DINO             | ✅ 支援（MIMIC-CXR為DICOM格式） | ✅ 以單幀為主             | ✅ 支援（JPEG、PNG）           | JPEG、PNG（透過PIL）                |
| FCDD                 | ❌ 不直接支援DICOM              | ✅ 單幀                  | ✅ 支援（需轉換）               | JPEG、PNG、BMP（需預處理）           |
| MedImageParse FAMILY | ✅ 支援（透過Azure ML API）     | ✅ 單幀                  | ✅ 支援（推薦PNG）              | PNG（推薦）、JPEG                   |
| PRISM                | ✅ 支援（透過OpenSlide讀取WSI） | ✅ 多幀（WSI切片）       | ✅ 支援（SVS、TIFF等）          | SVS、TIFF、PNG（透過OpenSlide）      |
| PROV-GIGAPATH        | ✅ 支援（WSI格式）              | ✅ 多幀（WSI切片）       | ✅ 支援（SVS、NDPI等）          | SVS、NDPI、TIFF（透過OpenSlide）     |
| CXR REPORTGEN        | ✅ 支援（MIMIC-CXR為DICOM）     | ✅ 單幀                  | ✅ 支援（PNG、JPEG）            | PNG、JPEG                           |

**說明與補充**
- Virchow FAMILY、PRISM 與 PROV-GIGAPATH 主要用於病理影像，支援多幀WSI格式，通常透過 OpenSlide 讀取 SVS、NDPI 等格式。
- RAD-DINO 與 CXR REPORTGEN 主要用於胸部X光，支援DICOM與常見影像格式（如JPEG、PNG），適用於單幀影像。
- FCDD 是通用異常偵測模型，不直接支援DICOM，但可透過預處理轉換為支援格式。
- MedImageParse 推薦使用PNG格式，適用於多模態影像分析，支援透過Azure API部署。

---

## 廠商影像的適應性
| 模型名稱            | 是否報告廠商差異 | 訓練資料來源                                   | 潛在影響因素                                         |
|---------------------|------------------|-----------------------------------------------|------------------------------------------------------|
| Virchow FAMILY      | ❌ 未報告         | 多中心病理切片（WSI），涵蓋17種組織類型         | 染色差異、掃描儀品牌（如Aperio vs Hamamatsu）可能影響顏色分布 |
| RAD-DINO            | ❌ 未報告         | MIMIC-CXR、VinDr-CXR、RSNA等公開資料集         | 影像解析度、對比度、雜訊水準可能因設備差異影響性能           |
| FCDD                | ❌ 未報告         | 工業與醫學影像（如MVTec-AD）                   | 對影像品質敏感，設備差異可能影響異常偵測熱圖                   |
| MedImageParse FAMILY| ❌ 未報告         | 多模態影像（CT、MRI、X光等）                   | 影像模態差異大，設備差異可透過提示詞適配                       |
| PRISM               | ❌ 未報告         | 病理影像（WSI）                               | 染色風格與掃描儀差異可能影響反事實生成品質                       |
| PROV-GIGAPATH       | ❌ 未報告         | Providence健康網路，31種組織類型               | 多中心資料增強泛化能力，但未報告廠商差異                         |
| CXR REPORTGEN       | ❌ 未報告         | MIMIC-CXR等公開資料集                          | 影像採集協議差異可能影響報告生成品質                               |

**說明與補充**
- 目前尚無模型明確報告在不同廠商設備上的準確率差異。
- 多數模型使用多中心資料訓練，具備一定的泛化能力，但仍可能受影像品質、解析度、染色風格等因素影響。
- 若您在實際部署中關注設備差異影響，建議：
  - 使用領域適應技術（如VPTTA、M2CD）進行模型微調；
  - 引入影像標準化預處理（如直方圖匹配、染色歸一化）；
  - 在本地採集資料上進行小樣本驗證，評估模型在特定設備上的表現。