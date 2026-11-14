# Shared validation rules for the five-Agent deployment configuration.
def nonempty: type == "string" and length > 0;
def https: nonempty and test("^https://[^/@?#[:space:]]+(:[0-9]+)?(/[^?#[:space:]]*)?$");
def positive_integer: test("^[1-9][0-9]*$");
def first_endpoint: map(select(type == "string" and length > 0)) | first | https;
def role_config:
  type == "object" and all(to_entries[]; (.key | test("^[A-Z][A-Z0-9_]*$")) and (.value | type == "string"))
  and all(.[]; index("\u0000") == null)
  and (.A2A_API_KEY | nonempty and length >= 24 and (test("[\\r\\n]") | not))
  and ((.DB_PROVIDER // "horizondb") | . == "horizondb" or . == "postgresql")
  and (.DB_ENDPOINT | nonempty and test("^[a-zA-Z0-9.-]+$")
       and . != "localhost" and . != "127.0.0.1" and . != "db")
  and ((.DB_AUTH_MODE // "password") | . == "password" or . == "entra")
  and (if (.DB_AUTH_MODE // "password") == "entra"
       then (.AZURE_CLIENT_ID | nonempty) and (.AZURE_CLIENT_SECRET == null)
       else (.DB_PASSWORD | nonempty) end)
  and (.DB_DATABASE | nonempty)
  and (.DB_USERNAME | nonempty)
  and ((.DB_PORT // "5432") | positive_integer and (tonumber <= 65535))
  and (.DB_SSL_MODE | . == "require" or . == "verify-ca" or . == "verify-full")
  and .BLOB_BACKEND == "azure"
  and .AZURE_STORAGE_CONTAINER == "data"
  and (.AZURE_STORAGE_ACCOUNT_URL | https)
  and (.LLM_MODEL | nonempty)
  and (.EMBEDDING_MODEL | nonempty)
  and ([.FOUNDRY_OPENAI_BASE_URL, .AGENT_APIM_ENDPOINT, .FOUNDRY_PROJECT_ENDPOINT] | first_endpoint)
  and (.AGENT_APIM_ENDPOINT | https)
  and (.FOUNDRY_EMBEDDING_BASE_URL == ((.AGENT_APIM_ENDPOINT | rtrimstr("/")) + "/openai/v1"))
  and .EMBEDDING_TOKEN_SCOPE == "https://ai.azure.com/.default"
  and ((.EMBEDDING_DIMENSIONS // "1536") | positive_integer and (tonumber <= 4096))
  and ((.MAX_CHUNKS // "100000") | positive_integer and (tonumber <= 200000))
  and ((.MAX_INGESTION_SPOOL_BYTES // "4294967296") | positive_integer and (tonumber <= 8589934592))
  and ((.INGESTION_TIMEOUT // "7200") | tonumber | . > 0 and . <= 86400)
  and ((.FOUNDRY_API_VERSION // "v1") == "v1")
  and (
    ([.AZURE_TENANT_ID, .AZURE_CLIENT_ID, .AZURE_CLIENT_SECRET] | all(. == null))
    or ((.AZURE_CLIENT_ID | nonempty) and .AZURE_CLIENT_SECRET == null
        and (.AZURE_TENANT_ID == null or (.AZURE_TENANT_ID | nonempty)))
    or ([.AZURE_TENANT_ID, .AZURE_CLIENT_ID, .AZURE_CLIENT_SECRET] | all(nonempty))
  );
type == "object"
and (keys | sort) == ["chat","data-processing","orchestrator","rag","sql"]
and all(.[]; role_config)
and ([.[] | .A2A_API_KEY] | unique | length) == 1
and ([.[] | [(.DB_PROVIDER // "horizondb"), .DB_ENDPOINT, (.DB_PORT // "5432"), .DB_DATABASE,
             .DB_USERNAME, (.DB_AUTH_MODE // "password"),
             (if (.DB_AUTH_MODE // "password") == "entra" then .AZURE_CLIENT_ID else .DB_PASSWORD end),
             .DB_SSL_MODE,
             ((.INGESTION_TIMEOUT // "7200") | tonumber),
             (.EMBEDDING_DIMENSIONS // "1536"), .EMBEDDING_MODEL,
             .FOUNDRY_EMBEDDING_BASE_URL, .EMBEDDING_TOKEN_SCOPE,
             .AZURE_STORAGE_ACCOUNT_URL, .AZURE_STORAGE_CONTAINER]] | unique | length) == 1
