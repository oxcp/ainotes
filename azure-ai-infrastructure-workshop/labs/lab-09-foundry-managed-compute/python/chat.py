import os
from openai import OpenAI

# Managed compute endpoints use key authentication.
# Set these from the deployment's Details / Consume tab:
#   MODEL_BASE_URL  e.g. https://<ENDPOINT_NAME>.<region>.inference.ml.azure.com/v1
#   MODEL_API_KEY   the endpoint key
#   MODEL_NAME      the served model name
client = OpenAI(
    base_url=os.environ["MODEL_BASE_URL"],
    api_key=os.environ.get("MODEL_API_KEY", "not-required"),
)

response = client.chat.completions.create(
    model=os.environ["MODEL_NAME"],
    messages=[
        {"role": "system", "content": "You are an Azure AI infrastructure assistant."},
        {"role": "user", "content": "Explain managed compute versus serverless deployment in three bullets."},
    ],
    temperature=0.2,
)
print(response.choices[0].message.content)
