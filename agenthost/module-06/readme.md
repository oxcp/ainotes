# Module 6 — Multi-Agent Business Scenarios

> 🌐 语言 / Language: **English** | [中文](readme_CN.md)

[⬆ Back to Workshop Home](../readme.md)

> **Suggested duration: 60 minutes**, following the 145-minute core workshop.

## Overview

- Business scenario: upload consumer reports, customer reviews and sales data, then ask five collaborating Agents for grounded business analysis.
- Implementation overview:
  - Each Agent runs in its own ACA Sandbox and communicates through **A2A**.
  - **LangGraph** coordinates tasks inside Orchestrator, and the **OpenAI SDK** calls Microsoft Foundry through the existing APIM gateway.
  - **Azure HorizonDB / PostgreSQL Flexible Server** stores structured data and vectors.
- Agent roles:

| Agent | Responsibility |
|---|---|
| Chat | Browser UI, Session management and file uploads |
| Orchestrator | Plan tasks, coordinate workers, synthesize and review answers |
| Data Processing | Extract files, load structured data and generate embeddings |
| RAG | Retrieve relevant passages with source citations |
| SQL | Generate, validate and execute bounded read-only queries |

## Architecture

```mermaid
%%{init: {"flowchart": {"nodeSpacing": 80, "rankSpacing": 100}}}%%
flowchart TD
    U["Browser"] -->|"Upload files<br/>Ask questions"| C["Chat"]
    C -->|"Store original<br/>files"| B[("Private Blob")]
    C -->|"A2A requests<br/>File references"| O["Orchestrator<br/>LangGraph"]
    O -->|"A2A<br/>Process uploads"| D["Data Processing"]
    O -->|"A2A<br/>RAG / HYBRID retrieval"| R["RAG"]
    O -->|"A2A<br/>SQL / HYBRID queries"| S["SQL"]
    B -->|"Read original<br/>files"| D
    D -->|"Store structured<br/>data and vectors"| H[("HorizonDB / PostgreSQL<br/>Data and vectors")]
    R -->|"Session-scoped<br/>vector search"| H
    S -->|"Read schema<br/>Run read-only SQL"| H
    O -->|"Manage Sessions<br/>Save completed runs"| H
    D -->|"Embed document<br/>chunks"| E["Foundry embeddings<br/>via APIM"]
    R -->|"Embed search<br/>queries"| E
    O -->|"Plan / DIRECT<br/>Synthesize / review"| L["Foundry general model<br/>via APIM"]
    S -->|Generate SQL| L
```

## Prerequisites

- Complete [Module-01](../module-01/README.md) and [Module-04](../module-04/README.md).
  Reuse their resource group, region, storage account, ACR, Foundry/APIM, managed identity (UAMI)
  and existing SandboxGroup. Keep the resource group's `deploymentSN` tag.
- Use Linux Bash (including WSL), Azure CLI with Bicep, the independent
  [`aca` CLI](https://aka.ms/aca-cli-install), `jq`, `curl`, `openssl`, GNU `timeout` and `realpath`.
  The deployment path was checked with ACA CLI `1.0.0-preview.5` and Bicep `0.48.1`.
- The operator needs database/model/APIM child-resource deployment permissions, storage ARM read/container
  deployment permissions, permission to attach the UAMI and run ACR Tasks, and
  **Container Apps SandboxGroup Data Owner** on the existing SandboxGroup.
- The UAMI needs model access, ACR pull permissions and **Storage Blob Data Contributor**.
  The selected database requires provider registration and regional capacity; HorizonDB also requires preview access.

### Existing private Blob mount (required for Bash deployment)

Deployment creates the private `data` container in the existing storage account and mounts it
**read-only at `/kb-data` in Chat and Data Processing**. The application still uses the Blob SDK
for uploads.

Private storage access requires Private Link, so complete Module-04's VNet/Private DNS setup first.

> [!CAUTION]
> This is a workshop deployment, not a production multi-user service:
> - Anyone who can reach the Chat URL can access all Sessions and their data; no browser key is required.
> - The default database firewall allows **all IPv4 sources** (`0.0.0.0`–`255.255.255.255`).
>   Use restricted rules/private networking outside the workshop. Adding narrower rules does not remove existing broad rules.
> - The shared UAMI receives database administrator privileges for workshop setup; production needs least-privilege SQL roles.

## Step 1 — Check the existing environment

From the repository root, enter this module. Run the remaining commands here in the **same Bash session**.

```bash
cd agenthost/module-06
az account show -o none 2>/dev/null || az login
aca auth status >/dev/null 2>&1 || aca auth login

export SUBSCRIPTION_ID="$(az account show --query id -o tsv | tr -d '\r\n')"
export RESOURCE_GROUP="${RESOURCE_GROUP:-rg-agenthost-workshop}"
export LOCATION="$(az group show --subscription "$SUBSCRIPTION_ID" -n "$RESOURCE_GROUP" --query location -o tsv | tr -d '\r\n')"
export DEPLOYMENT_SN="$(az group show --subscription "$SUBSCRIPTION_ID" -n "$RESOURCE_GROUP" --query tags.deploymentSN -o tsv | tr -d '\r\n')"
: "${DEPLOYMENT_SN:?Restore the resource group deploymentSN tag}"
export SANDBOX_GROUP_NAME="${SANDBOX_GROUP_NAME:-sandbox-group-agenthost-$DEPLOYMENT_SN}"
export ACA_OUTPUT="${ACA_OUTPUT:-$PWD/.local/aca-deployment.json}"

aca doctor --subscription "$SUBSCRIPTION_ID" --resource-group "$RESOURCE_GROUP" \
  --sandbox-group "$SANDBOX_GROUP_NAME" --region "$LOCATION"
```

Confirm the intended subscription, resource group, region and SandboxGroup, and resolve any failed checks.
Select the intended subscription with `az account set` before this block if necessary.
**Do not create another SandboxGroup.**

Confirm that the checks pass with output similar to the following:

```text
General checks:
✓ Azure CLI found
✓ Azure CLI logged in
✓ Subscription configured (624e6382-...) [config]
✓ Resource group configured (rg-agenthost-workshop) [config]
✓ ARM authentication working

Sandbox checks:
✓ Sandbox group: sandbox-group-agenthost-7a5970
✓ Region: westus3
✓ Sandbox group 'sandbox-group-agenthost-7a5970' exists in Azure
✓ Container Apps SandboxGroup Data Owner role assigned

9/9 passed

aca 1.0.0-preview.5 — all checks passed
```

## Step 2 — Deploy with one command

`DB_PROVIDER` defaults to **HorizonDB**. The available services are **HorizonDB | PostgreSQL**
(Azure PostgreSQL Flexible Server). Command values must be lowercase: `horizondb` (default) or `postgresql`.
Both use PostgreSQL 17, the `postgres` database and `vector`.

Before deployment, set the database provider and region in the current Bash shell:

```bash
export DB_PROVIDER="horizondb"  # Change to "postgresql" if needed
export DB_LOCATION="eastus2"   # Example: replace with a region supporting your chosen database service
```

> [!IMPORTANT]
> - **`DB_LOCATION` controls only the database deployment region; it can differ from the resource group's
>   and ACA SandboxGroup's regions.** If the previously selected region does not offer your chosen database
>   service, specify a supported region here.
> - Do not change the shared `LOCATION` or rebuild the SandboxGroup for this purpose.
> - `eastus2` above is only an example: verify database service/SKU availability and subscription quota in the target region.
> - When `DB_LOCATION` is unset, `LOCATION` takes precedence; otherwise the resource group's region is used.
> - Cross-region connections must still meet network access requirements and can increase latency and data transfer costs.

Only set overrides when your existing resources differ from the workshop defaults:

| Variable | When needed |
|---|---|
| `DB_PROVIDER` | `horizondb` (default) or `postgresql` |
| `DB_LOCATION` | Database-only region override, independent of the resource group/SandboxGroup; select a supported region if the original region lacks the chosen database service |
| `ACR_NAME`, `STORAGE_ACCOUNT_NAME`, `APIM_NAME` | Custom existing Module-01 resource names |
| `IMAGE_TAG` | Image tag shared by builds and ACA imports; defaults to `latest` |
| `FOUNDRY_RESOURCE_NAME`, `FOUNDRY_PROJECT_NAME` | Custom existing Foundry account/project; project defaults to `maf-agent-prj` |
| `LLM_MODEL` | Deployed general-model name when Module-01 deployment outputs cannot be used |
| `EMBEDDING_CAPACITY` | Defaults to `200` (200K TPM for `text-embedding-3-small`); requires sufficient regional model/SKU quota |
| `CUSTOMER_VNET_CONNECTION_NAME` | Select among multiple existing VNet connections |
| `DB_FIREWALL_RULES_FILE` | Custom database firewall rules |
| `ACA_COMMON` | Separate custom runtime JSON; normally omit and use automatic discovery |

Run the following command to complete the deployment required for this module:

```bash
bash deploy.sh --migrate
```

**This command creates billable resources.** It runs the following stages in order; do not run them
again individually after the full deployment:

| Stage | Action |
|---|---|
| `storage` | Create/reuse private `data` in the existing storage account |
| `models` | Deploy `text-embedding-3-small` with 200K TPM by default and add its route to the existing APIM |
| `database` | Deploy the selected database and configure UAMI Entra authentication |
| `config` | Discover model/storage settings and generate protected Agent configuration |
| `images` | Build and publish five images remotely using ACR Tasks |
| `aca` | Create five sandboxes, mount storage, apply the schema, start Agents and check connectivity |

The command must finish with all five Agents marked `ready`:

```text
AGENT             STATUS       URL
chat              ready        https://<chat-ingress>
orchestrator      ready        https://<orchestrator-ingress>
data-processing   ready        https://<processing-ingress>
rag               ready        https://<rag-ingress>
sql               ready        https://<sql-ingress>
Inventory: .../.local/aca-deployment.json
```

- The command also checks health endpoints, authenticated Agent Cards and a Chat → Orchestrator → database request.
- Generated settings, passwords, peer keys and resource inventories are saved under `.local`.
- Custom settings belong in a separate `ACA_COMMON` JSON with string values.

> [!important]
> - Auto-suspend is **disabled by default** because HTTP/A2A requests do not wake suspended Agents.
>   All five Agents therefore incur compute charges even when idle.
> - If you suspend them between exercises, explicitly resume all workers before using them again.

## Step 3 — Connect to a Session

```bash
jq -r '.agents.chat.url' "$ACA_OUTPUT"
```

1. Open the printed URL.
2. Select an existing **Session**, or enter `Summer launch` under **New session** and click **Create**.
3. Click **Connect** before uploading or asking questions.

A Session is a persistent workspace for uploaded data. Data is available only within the Session
to which it was uploaded. When switching Sessions, reconnect and upload data to the selected Session.

**Clear local conversation** clears browser history only, not stored data.

Enter sends a question; Shift+Enter inserts a newline.

## Step 4 — Upload and process sample data

Deployment does not import data automatically. Use the prepared PDF/CSV files in [sample-data](sample-data/).

Select one or more files, then click **Upload and process**. The browser uploads and processes them
**one at a time**.

| Order | Upload | File contents and processing result | Data source and link |
|---|---|---|---|
| 1 | [Capgemini (PDF: 20 pages)](sample-data/01_capgemini_consumer_trends_2025-pages-000001-000020.pdf) | Consumer trends report (pages 1–20); extract text and store searchable vectors | Capgemini Research Institute report: [what-matters-to-todays-consumer-2025](https://www.capgemini.com/us-en/insights/research-library/what-matters-to-todays-consumer-2025/). First 20 pages |
| 2 | [Ryder (PDF: 20 pages)](sample-data/02_ryder_ecommerce_consumer_study_2025-pages-000001-000020.pdf) | E-commerce consumer study (pages 1–20); extract text and store searchable vectors | Ryder insights report: [2025-ryder-ecommerce-consumer-study](https://www.ryder.com/globalassets/media/documents/insights/white-papers/2025-ryder-ecommerce-consumer-study_ada.pdf). First 20 pages |
| 3 | [Customer reviews (CSV: 2,000 rows)](sample-data/03_customer_reviews-rows-000001-002000.csv) | Customer reviews (rows 1–2,000); store typed rows and embed useful review text | Workshop-provided sample from a public source |
| 4 | [Financial report (CSV: 700 rows)](sample-data/04_financial_sample-rows-000001-000700.csv) | Financial sample data (700 rows); store typed rows; numeric financial data produces no embeddings | [Microsoft Power BI Financial Sample](https://learn.microsoft.com/en-us/power-bi/create-reports/sample-financial-download) |

- *The workshop sample data comes from publicly accessible sites.*
- *It is used only for technical testing in this workshop and is not guaranteed to be representative of the market.*

<!--
> - The complete review source has **41,711 rows in 21 parts**. Each CSV part becomes a separate
>   dataset/table; whole-dataset statistics must aggregate all relevant parts.
> - Default per-file limits are **20 MB**, **50,000 rows** and **100,000 embedding chunks**.
> - Do not upload both an original and its parts into one Session. Deduplication is per file, not across parts;
-->

**Upload steps:**
1. Confirm that you have selected the target **Session** and clicked **Connect**.
2. Select the local sample PDF/CSV files in the file picker. You can select multiple files at once.
3. Click **Upload and process** to start uploading and processing the selected files.
4. Keep the page open until the queue finishes uploading and processing each file. If an error pauses the queue, click **Retry last request** to retry.

After uploading, confirm that all selected files show "Completed" in the status area:

![module-06-files-upload-completed](../pic/module-06-files-upload-completed.png)

Click **Show sources** to view the files uploaded to the current Session.
Embedding runs automatically; there is no separate vectorization command.

**Keep the page open while the queue runs.**

> [!tip]
> - On an upload error, the queue pauses. Click **Retry last request** to continue the current file/run
>   without repeating completed files. Errors commonly occur when embedding generation hits capacity limits.
> - To raise the existing embedding deployment's TPM to address such errors, open model deployments in
>   the Microsoft Foundry project, find the deployed "text-embedding-3-small" model, select "Edit",
>   and increase "Tokens per Minute Rate Limit".
> - Large ingestions may take up to the default **7,200-second** ingestion deadline; allow for model quota and cost.
> - Use text PDFs; OCR is not supported.

## Step 5 — Ask questions and verify Agent behavior

Ask the following in the same Session after its relevant uploads finish. The model selects the route;
there is no manual mode selector.

| Mode | Example question | Data retrieval |
|---|---|---|
| DIRECT | Write three taglines for a repairable speaker. | General-model response, without retrieval or SQL |
| RAG | According to the uploaded reports, what matters to consumers? | Vector retrieval of relevant passages, filenames, pages and citations |
| SQL | Which country generated the highest total profit? Show a bar chart and data table. | SQL queries, with totals consistent with the financial CSV |
| HYBRID | Combine consumer trends and sales performance and recommend the best launch market. | Both vector retrieval and SQL queries, with combined results |

Each response appears in the history panel. Expand its "Evidence, SQL and execution plan" section to see:
- The routing mode selected by the model.
- The task workflow planned by the Orchestrator Agent, including which Agents participate, their goals, the RAG retrieval strategy, whether to generate charts, the answer language, and more.
- The collaboration between Agents and each Agent's inputs and responses.
- The final synthesis and review performed by the Orchestrator Agent.

![module-06-chat-response+evidence](../pic/module-06-chat-response+evidence.png)

<details>
<summary>Expand to view a complete HYBRID response example (Chinese model text translated into English)</summary>

![module-06-chat-response+evidence-hybrid](../pic/module-06-chat-response+evidence-hybrid.png)

```text
{
  "mode": "HYBRID",
  "plan": {
    "mode": "HYBRID",
    "reason": "Recommending a market requires both structured sales/profit summaries and source passages from consumer trend reports: SQL calculates sales performance by market, while RAG extracts consumer trends and market context from the reports to support the explanation.",
    "rag_goal": "Use 01_capgemini_consumer_trends_2025.pdf and 02_ryder_ecommerce_consumer_study_2025.pdf to retrieve consumer trends, purchasing preferences, price sensitivity, regional/market differences and indicators of product launch suitability relevant to market selection.",
    "sql_goal": "Aggregate sales and profit performance by country from 04_financial_sample.csv, focusing on each country's total sales and profit and the comparative rankings needed to recommend the most suitable product launch market.",
    "rag_strategy": "semantic",
    "chart_intent": "none",
    "answer_language": "Simplified Chinese",
    "tasks": [
      {
        "worker": "rag_agent",
        "goal": "Use 01_capgemini_consumer_trends_2025.pdf and 02_ryder_ecommerce_consumer_study_2025.pdf to retrieve consumer trends, purchasing preferences, price sensitivity, regional/market differences and indicators of product launch suitability relevant to market selection.",
        "depends_on": []
      },
      {
        "worker": "sql_agent",
        "goal": "Aggregate sales and profit performance by country from 04_financial_sample.csv, focusing on each country's total sales and profit and the comparative rankings needed to recommend the most suitable product launch market.",
        "depends_on": []
      }
    ]
  },
  "documents": {
    "status": "weak",
    "results": [
      {
        "record_id": "5856ffb2-bd44-4e6d-8028-acf45d00ea96",
        "workspace_id": "3316b200-58be-4bb4-aa26-8cb472ba91ef",
        "document_id": "eec4d614-566c-48be-9fda-f00e18d9488d",
        "filename": "01_capgemini_consumer_trends_2025-pages-000001-000020.pdf",
        "content": "We identified five distinct behavior clusters based on the \nsub-themes on which questions were asked in the consumer \nsurvey:\nSource: Capgemini Research Institute, Consumer Demand survey, October–November 2024, N = 12,000 consumers; Educated \nRationalists cluster = 2,462 consumers; Convenience-Led Urbanites cluster = 3,556 consumers; Grounded Suburbanites cluster = \n1,912 consumers; Digital-First Trailblazers cluster = 2,660 consumers; Traditionalists cluster = 1,410 consumers.\nFigure 1.\nConsumer trends clusters \n12%\n16%\n21%\n22%\n30%\nTraditionalists  \nGrounded Suburbanites \nEducated Rationalists Digital-First Trailblazers \nConvenience-Led Urbanites  \nUsage of Gen AI\nSocial media influence\nSustainability impact\nOnline advertisements\nCost of living \n(Last-mile) convenience\nLoyalty\n9\nCapgemini Research Institute 2025\nWhat matter to today’s consumer? 2025 consumer behavior tracker for the consumer product and retail industries",
        "similarity_score": 0.516250412399397,
        "page_number": 9,
        "section": null,
        "metadata": {
          "language": "en"
        }
      },
      {
        "record_id": "34550ca0-2808-419b-9afa-68a0ab6bfb22",
        "workspace_id": "3316b200-58be-4bb4-aa26-8cb472ba91ef",
        "document_id": "70bf51ee-7e42-4ad5-bf99-667622a252a8",
        "filename": "02_ryder_ecommerce_consumer_study_2025-pages-000001-000020.pdf",
        "content": "PURCHASE BEHAVIOR | 12\nPURCHASE BEHAVIOR | 13\nPURCHASE BEHAVIOR: \nKEY TAKEAWAYS\n• Experience is the leading driver of physical \nshopping.\n• Price comparison is the most commonly used \nresearch method among online shoppers.\n• Cleaning products, toys, and vitamins/\nsupplements exhibited the most annual \ngrowth. \n• Holiday purchasing patterns signal key \nomnichannel and consumer loyalty \nopportunities.",
        "similarity_score": 0.5390977324415074,
        "page_number": 13,
        "section": null,
        "metadata": {
          "language": "en"
        }
      },
      {
        "record_id": "34bcd495-b5f9-4a19-b67b-d43a9fc5d24a",
        "workspace_id": "3316b200-58be-4bb4-aa26-8cb472ba91ef",
        "document_id": "eec4d614-566c-48be-9fda-f00e18d9488d",
        "filename": "01_capgemini_consumer_trends_2025-pages-000001-000020.pdf",
        "content": "Executive \nsummary \nSeeing the light: The beginning of the end of the cost-\nof-living crisis?\nAlthough the cost-of-living crisis continues to impact \nconsumer sentiment, things are slowly improving. \nHowever, consumers still seek discounts, both online and \nin-store. Private-label sales are on the rise as consumers \nlook for more affordable options.   \n• 64% of shoppers visit multiple physical stores looking \nfor deals, up from 56% last year.\n• Currently, 65% of consumers buy private-label or low-\ncost brands, up from 63% last year.\n• 73% of millennials expect retailers to provide alerts \nwhen brands reduce the weight of a product without \nreducing the price (‘shrinkflation’).\n \nThe grass is greener: Why consumers are \nswitching brands\n \n• 70% of consumers globally switch to try new brands. Another \nmajor reason for switching brands, as stated by 65% of \nconsumers, was that membership programs and shared \npreference data failed to result in a better experience.\n• Two-thirds of consumers will switch food brands for higher \nnutrition scores. \nTo remain competitive, brands and retailers must augment Gen AI \ntools to become more consumer-centric, use technology to boost \nresilience and sustainability and lower prices, leverage social and \nretail media networks as a keyway to engage and influence early in \nthe consumer journey, and bridge the gap in consumer education \nand trust with transparent collaboration across all partners.\n6\nCapgemini Research Institute 2025\nWhat matter to today’s consumer? 2025 consumer behavior tracker for the consumer product and retail industries",
        "similarity_score": 0.5088272243476892,
        "page_number": 6,
        "section": null,
        "metadata": {
          "language": "en"
        }
      },
      {
        "record_id": "e333d479-fb07-4b6a-81de-d61b38f1520b",
        "workspace_id": "3316b200-58be-4bb4-aa26-8cb472ba91ef",
        "document_id": "70bf51ee-7e42-4ad5-bf99-667622a252a8",
        "filename": "02_ryder_ecommerce_consumer_study_2025-pages-000001-000020.pdf",
        "content": "PURCHASE BEHAVIOR",
        "similarity_score": 0.4901920565175468,
        "page_number": 12,
        "section": null,
        "metadata": {
          "language": "en"
        }
      },
      {
        "record_id": "d1281d59-ee99-4be9-bf9e-383ab60d4f1e",
        "workspace_id": "3316b200-58be-4bb4-aa26-8cb472ba91ef",
        "document_id": "b3002d48-de4a-42f5-97ce-b25511b16f73",
        "filename": "01_capgemini_consumer_trends_2025-pages-000041-000060.pdf",
        "content": "trend highlights \na growing impatience and desire for immediate \ngratification among consumers.\n70\n%\nof consumers are willing to pay more  \nfor quick delivery\n52\nCapgemini Research Institute 2025\nWhat matter to today’s consumer? 2025 consumer behavior tracker for the consumer product and retail industries",
        "similarity_score": 0.5057642285570623,
        "page_number": 12,
        "section": null,
        "metadata": {
          "language": "en"
        }
      }
    ],
    "top_k": 5,
    "retrieval_method": "semantic",
    "truncated": true,
    "warnings": [
      "Search 01_capgemini_consumer_trends_2025.pdf / market selection consumer trends purchase preferences price sensitivity regional differences market attractiveness: 5 candidates above threshold, 3 retained.",
      "Search 02_ryder_ecommerce_consumer_study_2025.pdf / market selection consumer trends purchase preferences price sensitivity regional differences market attractiveness: 5 candidates above threshold, 2 retained.",
      "Search coverage is bounded by the current file inventory and similarity threshold. A matching passage is not proof of every requested theme; verify its text. Missing evidence is not evidence that a report lacks a theme.",
      "Evidence was capped by the merged record/context budget; coverage is partial."
    ]
  },
  "query": {
    "sql": "WITH country_summary AS (SELECT country, SUM(sales) AS total_sales, SUM(profit) AS total_profit, COUNT(*) AS row_count FROM (SELECT * FROM ds_10552e69c5c04c309340a4390cb97890 WHERE workspace_id = '3316b200-58be-4bb4-aa26-8cb472ba91ef') AS ds_10552e69c5c04c309340a4390cb97890 GROUP BY country), ranked AS (SELECT country, total_sales, total_profit, row_count, ROUND(total_profit / NULLIF(total_sales, 0), 6) AS profit_margin, RANK() OVER (ORDER BY total_sales DESC, total_profit DESC) AS sales_rank, RANK() OVER (ORDER BY total_profit DESC, total_sales DESC) AS profit_rank FROM country_summary) SELECT country, total_sales, total_profit, profit_margin, sales_rank, profit_rank, CASE WHEN sales_rank = 1 AND profit_rank = 1 THEN TRUE ELSE FALSE END AS recommended_market_flag FROM ranked ORDER BY total_sales DESC, total_profit DESC, country LIMIT 100",
    "columns": [
      "country",
      "total_sales",
      "total_profit",
      "profit_margin",
      "sales_rank",
      "profit_rank",
      "recommended_market_flag"
    ],
    "rows": [
      {
        "country": "United States of America",
        "total_sales": "25029830.18",
        "total_profit": "2995540.68",
        "profit_margin": "0.119679",
        "sales_rank": 1,
        "profit_rank": 4,
        "recommended_market_flag": false
      },
      {
        "country": "Canada",
        "total_sales": "24887654.89",
        "total_profit": "3529228.89",
        "profit_margin": "0.141806",
        "sales_rank": 2,
        "profit_rank": 3,
        "recommended_market_flag": false
      },
      {
        "country": "France",
        "total_sales": "24354172.29",
        "total_profit": "3781020.79",
        "profit_margin": "0.155251",
        "sales_rank": 3,
        "profit_rank": 1,
        "recommended_market_flag": false
      },
      {
        "country": "Germany",
        "total_sales": "23505340.82",
        "total_profit": "3680388.82",
        "profit_margin": "0.156577",
        "sales_rank": 4,
        "profit_rank": 2,
        "recommended_market_flag": false
      },
      {
        "country": "Mexico",
        "total_sales": "20949352.11",
        "total_profit": "2907523.11",
        "profit_margin": "0.138788",
        "sales_rank": 5,
        "profit_rank": 5,
        "recommended_market_flag": false
      }
    ],
    "row_count": 5,
    "summary": "Executed read-only query; returned 5 rows.",
    "warnings": [
      "Query scope: 1 catalog dataset(s): 04_financial_sample-rows-000001-000700.csv. The bounded catalog is not proof of complete uploaded-file coverage."
    ]
  },
  "review": {
    "status": "approved",
    "unsupported_claims": [],
    "conflicts": [],
    "required_changes": [],
    "notes": [
      "The conclusion is explicitly labeled as a recommendation, and the partial coverage limitations of the retrieval and SQL results are disclosed.",
      "The financial comparison is based only on the five returned countries; it does not claim to represent all markets.",
      "The statements about retrieved consumer trends and purchasing preferences are consistent with the cited evidence."
    ],
    "chart_issues": []
  },
  "errors": []
}
```

</details>

### More example questions

**The following questions are examples for reference and can be copied one at a time.**

| No. | Expected mode | Chat question |
|---|---|---|
| 1 | DIRECT (direct response) | Explain the difference between sales, profit and profit margin in plain language, with a simple example. Do not use uploaded data. |
| 2 | RAG (vector retrieval) | Find contrasting experiences of high expectations followed by disappointment and exceeded expectations in the reviews. Quote the original text, state any missing evidence and do not compute counts. |
| 3 | RAG (vector retrieval) | Quote passages about price, convenience and sustainable consumption from the reports, then compare similarities and differences. Do not judge themes lacking source text. |
| 4 | RAG (vector retrieval) | Extract comparison percentages for purchasing Gen AI-recommended products from the reports. Quote the source and show a bar chart, preserving its time periods and populations; state if comparable values are unavailable. |
| 5 | SQL (structured queries) | Summarize total profit by country and show a bar chart and data table. |
| 6 | SQL (structured queries) | Aggregate sales and profit by year and month from the uploaded financial data and show a line chart. List profit margin (total profit / total sales) separately in a table; identify months when sales rose but profit did not versus the previous month. |
| 7 | SQL (structured queries) | Count the uploaded reviews and their percentages by sentiment category. Show a pie chart, total sample size and data coverage. |
| 8 | HYBRID (combined retrieval and multi-Agent collaboration) | Compare negative-review rates across platforms (such as apps or websites), using sentiment categories. Show a bar chart of rates and ground suggestions in review quotations; state if none are available. |
| 9 | HYBRID (combined retrieval and multi-Agent collaboration) | Calculate total sales and total profit from the financial data, and use reviews and reports to summarize customer experience and market risks. Do not chart. |
| 10 | HYBRID (combined retrieval and multi-Agent collaboration) | Calculate total sales and total profit from the financial data, and use customer needs in the reviews and consumer trends in the reports to recommend priority business improvements for the future. Do not chart. |

*"Expected mode" is the data retrieval and aggregation approach the model is expected to select, not a manual routing setting.*

> [!tip]
> - The DIRECT example requires no uploads. For the other questions, finish uploading and processing
>   the relevant files in the same Session first.
> - Retrieval and synthesis use only the uploaded data.
> - If a retrieval finds no relevant passage for a report or theme, the answer will identify the evidence gap.

### Reviewing answers

- Expand the evidence panel to inspect sources and SQL.
- Charts must use verified data; passage counts are not review-row counts.
- A broad review overview may use only five passages and is **not a full-dataset summary**.
- Use SQL for sentiment distributions and other dataset-wide counts.

### In-chat analytical charts

- Chat messages support bar, line and pie charts and numeric comparison tables; the AI can select a suitable visualization.
- SQL/HYBRID charts use actual query results. When explicitly requested, RAG can also use retrieved numeric
  metadata or values anchored to quotations from retrieved documents.
- Each answer supports up to four charts, with up to four series and 40 rows per chart.
- Chart errors are explicit and preserve the text answer. Charts persist with completed runs and are also
  saved in the browser's latest 30 local messages.
- Refreshing the same tab and reconnecting to the same Session restores local history.
  Clearing local history does not delete server-side runs.
- Also ask about a topic absent from the uploads: the answer should acknowledge insufficient evidence.
- Each Session should have its own uploaded files. Select a second Session and check **Show sources**:
  the first Session's files should not appear there.
- In a new Session, try uploading your own data files from outside this workshop and test them with relevant questions.

## Step 6 — Clean up

When finished, preview cleanup, review the targets, then execute:

```bash
bash cleanup.sh
source ./cleanup.sh --execute
```

Type **`delete module-06`** when prompted.

> [!WARNING]
> - Cleanup destroys Module-06 database/Blob/Sandbox data, including attributable snapshots.
> - After cloud cleanup is verified, it also empties this module's entire `.local`, including hidden files,
>   custom files and subdirectories.

<!--
The script uses saved `.local` inventories for **all deployment attempts**. It removes Module-06 sandboxes,
imported disks, attributable snapshots, the recorded Blob volume and `data` container, tagged databases/
parameter groups, and baseline-tracked embedding/APIM additions.
It preserves the shared resource group, SandboxGroup, Module-04 sandboxes, UAMI/RBAC, VNet, ACR/images,
Foundry account/project, general model, base APIM and storage account.

Missing ownership records or failed deletions stop complete cleanup and retain recovery files.
Review external/custom inventories separately. Dry runs, cancellation and failures do not reset environment
variables; changes to local files during cleanup also stop local deletion. Do not deploy concurrently
with cleanup or empty `.local` beforehand: the script needs its inventories to verify cloud ownership.

When invoked with `source`, cloud deletion still runs in a separate Bash process. Only after complete success does it
`unset` known Module-06 deployment variables in the current Bash shell, including `ACA_COMMON`, `ACA_CONFIG`,
`ACA_OUTPUT`, database settings/passwords, image tags, model/storage/identity settings, and subscription,
resource-group and region selections. It does not clear unrelated variables, edit shell startup files,
delete external custom configurations, or clear Azure CLI login/defaults. Readonly variables or namerefs
are rejected before deletion; use a clean Bash shell in that case.
`bash cleanup.sh --execute` still cleans cloud resources and local files, but a child process cannot unset
its caller's environment variables, so the `source` invocation above is recommended.
-->
> [!important]
> - To redeploy Module-06, **start again from Step 1 (environment setup, subscription, resource group,
>   database options, and so on)**, then run `bash deploy.sh --migrate`.
> - Do not delete the shared resource group to clean up only this module.

## References

- [Developer README](agent-src/README.md): local development, APIs and tests.
- [Runtime settings](agent-src/.env.example) and [CLI deployment](agent-src/docs/cli-deployment.md):
  advanced configuration and stage operations.
- [Architecture](agent-src/docs/architecture.md), [orchestration](agent-src/docs/orchestration.md)
  and [data processing](agent-src/docs/data-processing.md): implementation details.
- [Security and cleanup](agent-src/docs/security.md) and
  [implementation report](agent-src/docs/implementation-report.md): limitations and recorded validation evidence.

This workshop has no production multi-user authentication/RLS, OCR, durable recovery of interrupted workflows
or automatic data retention cleanup. Recorded local/mock tests do not establish live Azure acceptance;
verify your deployment with Steps 4–5.

[⬆ Back to Workshop Home](../readme.md)
