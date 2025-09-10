## 模型技术架构与技术参考

| 模型名称              | 技术架构/方法                                      | 相关论文/文档                                                         |
|----------------------|----------------------------------------------------|-----------------------------------------------------------------------|
| Virchow FAMILY       | Vision Transformer (ViT-H)，自监督学习（DINOv2）    | [Hugging Face Model Card](https://huggingface.co/paige-ai/Virchow2) <br> [Paige 官方Blog](https://www.paige.ai/blog/the-virchow-foundation-model-explained-a-qa-with-an-ai-scientist/) <br> [arXiv:2309.07778](https://arxiv.org/abs/2309.07778) <br> [arXiv:2309.07778 pdf](https://arxiv.org/pdf/2309.07778) <br> [arXiv:2408.00738](https://arxiv.org/abs/2408.00738)                           |
| RAD-DINO             | Vision Transformer，DINOv2自监督学习                | [Hugging Face Model Card](https://huggingface.co/microsoft/rad-dino) <br> [arXiv:2401.10815](https://arxiv.org/abs/2401.10815) <br> [zhihu Blog](https://zhuanlan.zhihu.com/p/24305678785)                           |
| FCDD                 | 全卷积网络（Fully Convolutional Data Description）  | [GitHub / ICLR 2021 Paper](https://github.com/liznerski/fcdd) <br> [arXiv:2206.02598](https://arxiv.org/pdf/2206.02598)                            |
| MedImageParse FAMILY <br>(Azure AI Foundry有提供) | Transformer架构，任务适配层，支持文本提示           | [Microsoft Learn 文档](https://learn.microsoft.com/en-us/azure/ai-foundry/how-to/healthcare-ai/deploy-medimageparse)                       |
| PRISM                | 基于Stable Diffusion的生成式模型，语言引导           | [MIDL 2025 会议论文](https://www.familydoctor.cn/news/prism-yizhong-yongyu-yixueyingxiang-kejieshi-chengshi-ai-moxing-121851.html) <br> [Science Bulletin 2024](https://www.x-mol.com/paper/1825036485145468928/t)            |
| PROV-GIGAPATH        | GigaPath架构 + LongNet，ViT-G/14，DINOv2预训练      | [GitHub](https://github.com/prov-gigapath/prov-gigapath) <br> [Nature 2024](https://zhuanlan.zhihu.com/p/1887815114905846462)                   |
| CXR REPORTGEN <br>(Azure AI Foundry有提供)       | BiomedCLIP图像编码器 + Phi-3-Mini语言模型           | [Microsoft Learn 文档](https://learn.microsoft.com/en-us/azure/ai-foundry/how-to/healthcare-ai/deploy-cxrreportgen)                 |

---

## 模型擅长疾病详细列表

| 模型名称            | 擅长识别的疾病/任务                                                                                         |
|--------------------|-------------------------------------------------------------------------------------------------------------|
| Virchow FAMILY     | **常见癌症：** 乳腺癌、肺癌、前列腺癌、结直肠癌、胃癌、肝癌、膀胱癌、子宫内膜癌、卵巢癌<br>**罕见癌症：** 神经内分泌肿瘤、软组织肉瘤、胰腺癌、胆管癌、脑肿瘤、骨肉瘤、肾上腺癌<br>**生物标志物预测：** HER2、ER、PR、TP53、KRAS、EGFR 等 |
| RAD-DINO           | **胸部X光疾病：** 肺炎、肺气肿、肺不张、肺结节、肺纤维化、肺气胸、心脏肥大、主动脉扩张、胸腔积液、胸管、气管偏移、纵隔增宽、骨折、支气管炎、结核、肿瘤等 |
| FCDD               | **异常检测（无特定疾病标签）：** 检测图像中与正常分布不符的区域，如肿瘤、病灶、结构异常、药丸缺陷、FCD II型癫痫病灶等 |
| MedImageParse      | **多模态图像任务：** 支持CT、MRI、X光、病理图像等的分割、检测、识别<br>**识别对象：** 脑肿瘤、肝脏病变、肺结节、心脏结构、骨折、眼底病变、肾脏病变、乳腺肿块、前列腺病变等（通过文本提示控制） |
| PRISM              | **癌症检测与报告生成：** 乳腺癌、前列腺癌、胃肠道癌、胰腺癌、肝癌、肺癌、神经内分泌肿瘤、罕见癌症等<br>**任务类型：** 零样本癌症检测、病理报告生成、病理问答、多轮诊断对话 |
| PROV-GIGAPATH      | **癌症亚型分类与病理组学任务：** 乳腺癌、肺癌、结直肠癌、胃癌、肝癌、胰腺癌、前列腺癌、脑肿瘤、骨肉瘤等<br>**任务类型：** 癌症亚型识别、肿瘤微环境分析、生物标志物预测、视觉-语言对齐 |
| CXR REPORTGEN      | **胸部X光报告生成：** 肺炎、肺气胸、心脏肥大、胸腔积液、肺结节、气管偏移、骨折、支气管炎、结核、肿瘤等<br>**任务类型：** 定位病灶、生成结构化报告、对比历史影像 |

**说明与补充**
- Virchow FAMILY 和 PROV-GIGAPATH 是目前最强的病理基础模型，支持多种癌症的检测与亚型分类。
- RAD-DINO 和 CXR REPORTGEN 专注于胸部X光，前者用于分类与分割，后者用于报告生成。
- FCDD 是无监督异常检测模型，适用于缺乏标签的医学图像。
- MedImageParse 是多模态统一模型，支持通过文本提示识别任意医学对象。
- PRISM 是唯一支持多轮问答与报告生成的病理模型，强调临床语言理解。

---

## 模型适用人群
| 模型名称           | 适用人群描述                                   | 是否适用于2岁以下患者 |
|--------------------|-----------------------------------------------|----------------------|
| Virchow FAMILY     | 成人患者，尤其是癌症患者；训练数据来自10万+成人患者的病理切片 | ❌ 未明确支持儿童或婴幼儿病理图像 |
| RAD-DINO           | 成人胸部X光患者；训练数据来自MIMIC-CXR等成人数据集         | ❌ 未明确支持2岁以下儿童         |
| FCDD               | 通用异常检测模型，适用于工业和医学图像；无特定人群限制         | ✅ 可用于儿童图像，但需自定义训练数据 |
| MedImageParse FAMILY | 多模态医学图像分析，适用于研究用途；未用于临床             | ❌ 不建议用于临床诊断，包括儿童   |
| PRISM              | 成人病理图像生成与解释；强调可解释性与反事实生成             | ❌ 未明确支持儿童病理图像         |
| PROV-GIGAPATH      | 成人癌症患者；训练数据来自30,000+成人患者的病理切片           | ❌ 未明确支持儿童或婴幼儿         |
| CXR REPORTGEN      | 成人胸部X光报告生成；训练数据来自MIMIC-CXR等成人数据集         | ❌ 不建议用于儿童，尤其是2岁以下   |

**说明与补充**
- Virchow FAMILY 和 PROV-GIGAPATH 均基于成人病理切片训练，未在儿童样本上验证。
- RAD-DINO 和 CXR REPORTGEN 使用的MIMIC-CXR数据集主要来自成人患者，未包含婴幼儿。
- FCDD 是唯一一个可通过自定义训练数据适配儿童图像的模型，但需自行准备数据。
- MedImageParse 和 PRISM 明确声明仅用于研究用途，不适用于临床诊断或儿童患者。

---

## 模型准确性表现
| 模型名称         | 准确性表现 | 高准确率疾病         | 性能下降条件                  |
|------------------|--------------------|-----------------------|------------------------------|
| Virchow FAMILY   | AUC高达0.95（平均），在乳腺癌、肺癌、胰腺癌等任务中表现优异 | 肺癌（AUC 0.989）、胰腺癌（AUC 0.983）、乳腺癌（AUC 0.974） | 在子宫颈癌等罕见癌症中AUC略低（如0.875） |
| RAD-DINO         | 在VinDr-CXR、RSNA-Pneumonia等数据集上表现优异，尤其在肺气胸和胸管检测上超越多模态模型 | 肺气胸、胸管、肺炎 | 在心脏肥大、主动脉扩张等任务中略逊于多模态模型 |
| FCDD             | 在MVTec-AD等工业数据集上达到SOTA，在医学图像中表现依赖于训练数据质量 | 癫痫病灶、药丸缺陷等异常检测 | 对于复杂结构或高噪声图像，解释性热图可能不稳定 |
| MedImageParse FAMILY | 未公开具体准确率，强调多模态统一性和任务适配能力 | 多模态图像分割、检测、识别 | 不适用于临床，性能依赖提示质量和图像模态 |
| PRISM            | 在零样本癌症检测中AUC达0.952，报告生成质量接近专家水平 | 罕见癌症、乳腺癌、前列腺癌 | 对于低质量图像或语言提示不明确时性能下降 |
| PROV-GIGAPATH    | 在26项任务中25项达SOTA，尤其在癌症亚型分类和病理组学任务中表现突出 | 乳腺癌、肺癌、结直肠癌等 | 对于极端稀有病理类型或低质量切片，性能可能下降 |
| CXR REPORTGEN    | CheXpert F1-14达59.1，RadGraph-F1达40.8，报告生成质量高 | 肺炎、肺气胸、心脏肥大等 | 对于缺乏历史影像或报告的病例，生成质量下降 |

**说明与补充**
- Virchow FAMILY 和 PROV-GIGAPATH 是目前在病理图像分析中表现最强的基础模型，适用于多种癌症检测任务。
- RAD-DINO 在胸部X光分类和分割任务中表现优异，尤其在肺气胸等任务中超过多模态模型。
- FCDD 是异常检测模型，适用于无标签或少标签场景，但对图像质量敏感。
- MedImageParse 强调多模态统一性，适用于研究用途，但未公开准确率。
- PRISM 是唯一支持反事实生成和多轮问答的模型，适用于临床解释性任务。
- CXR REPORTGEN 在报告生成任务中表现良好，适合用于自动化报告草稿生成。

---

## 模型格式支持
| 模型名称              | 支持DICOM格式 | 支持单帧/多帧         | 支持非DICOM格式           | 支持的非DIwCOM格式         |
|----------------------|:-------------:|:---------------------:|:-------------------------:|:--------------------------|
| Virchow FAMILY       | ✅ 支持（通过OpenSlide读取WSI） | ✅ 多帧（WSI切片）      | ✅ 支持（如SVS、NDPI、TIFF等） | SVS、NDPI、TIFF、PNG（通过OpenSlide） |
| RAD-DINO             | ✅ 支持（MIMIC-CXR为DICOM格式） | ✅ 单帧为主             | ✅ 支持（JPEG、PNG）           | JPEG、PNG（通过PIL）                |
| FCDD                 | ❌ 不直接支持DICOM              | ✅ 单帧                  | ✅ 支持（需转换）               | JPEG、PNG、BMP（需预处理）           |
| MedImageParse FAMILY | ✅ 支持（通过Azure ML API）     | ✅ 单帧                  | ✅ 支持（PNG推荐）              | PNG（推荐）、JPEG                   |
| PRISM                | ✅ 支持（通过OpenSlide读取WSI） | ✅ 多帧（WSI切片）       | ✅ 支持（SVS、TIFF等）          | SVS、TIFF、PNG（通过OpenSlide）      |
| PROV-GIGAPATH        | ✅ 支持（WSI格式）              | ✅ 多帧（WSI切片）       | ✅ 支持（SVS、NDPI等）          | SVS、NDPI、TIFF（通过OpenSlide）     |
| CXR REPORTGEN        | ✅ 支持（MIMIC-CXR为DICOM）     | ✅ 单帧                  | ✅ 支持（PNG、JPEG）            | PNG、JPEG                           |

**说明与补充**
- Virchow FAMILY、PRISM 和 PROV-GIGAPATH 主要用于病理图像，支持多帧WSI格式，通常通过 OpenSlide 读取 SVS、NDPI 等格式。
- RAD-DINO 和 CXR REPORTGEN 主要用于胸部X光，支持DICOM和常见图像格式（如JPEG、PNG），适用于单帧图像。
- FCDD 是通用异常检测模型，不直接支持DICOM，但可通过预处理转换为支持格式。
- MedImageParse 推荐使用PNG格式，适用于多模态图像分析，支持通过Azure API部署。

---

## 厂商图像的适应性
| 模型名称            | 是否报告厂商差异 | 训练数据来源                                   | 潜在影响因素                                         |
|---------------------|------------------|-----------------------------------------------|------------------------------------------------------|
| Virchow FAMILY      | ❌ 未报告         | 多中心病理切片（WSI），涵盖17种组织类型         | 染色差异、扫描仪品牌（如Aperio vs Hamamatsu）可能影响颜色分布 |
| RAD-DINO            | ❌ 未报告         | MIMIC-CXR、VinDr-CXR、RSNA等公开数据集         | 图像分辨率、对比度、噪声水平可能因设备差异影响性能           |
| FCDD                | ❌ 未报告         | 工业与医学图像（如MVTec-AD）                   | 对图像质量敏感，设备差异可能影响异常检测热图                   |
| MedImageParse FAMILY| ❌ 未报告         | 多模态图像（CT、MRI、X光等）                   | 图像模态差异大，设备差异可能通过提示词适配                       |
| PRISM               | ❌ 未报告         | 病理图像（WSI）                               | 染色风格和扫描仪差异可能影响反事实生成质量                       |
| PROV-GIGAPATH       | ❌ 未报告         | Providence健康网络，31种组织类型               | 多中心数据增强了泛化能力，但未报告厂商差异                         |
| CXR REPORTGEN       | ❌ 未报告         | MIMIC-CXR等公开数据集                          | 图像采集协议差异可能影响报告生成质量                               |

**说明与补充**
- 当前尚无模型明确报告在不同厂商设备上的准确率差异。
- 多数模型使用多中心数据训练，具备一定的泛化能力，但仍可能受到图像质量、分辨率、染色风格等因素影响。
- 若在实际部署中关注设备差异影响，建议：
  - 使用领域适应技术（如VPTTA、M2CD）进行模型微调；
  - 引入图像标准化预处理（如直方图匹配、染色归一化）；
  - 在本地采集数据上进行小样本验证，评估模型在特定设备上的表现。