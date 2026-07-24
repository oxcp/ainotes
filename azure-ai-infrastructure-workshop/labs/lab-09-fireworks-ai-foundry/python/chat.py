import os
from openai import OpenAI

# Fireworks AI on Foundry is consumed as an OpenAI-compatible managed endpoint.
# Set these from the deployment's Consume tab:
#   MODEL_BASE_URL  OpenAI-compatible base URL (ends in /v1)
#   MODEL_API_KEY   the endpoint key
#   MODEL_NAME      the served model name
client = OpenAI(
    base_url=os.environ["MODEL_BASE_URL"],
    api_key=os.environ["MODEL_API_KEY"],
)

response = client.chat.completions.create(
    model=os.environ["MODEL_NAME"],
    messages=[
        {"role": "system", "content": "You are an Azure AI infrastructure assistant."},
        {"role": "user", "content": "When should I use a partner MaaS model instead of dedicated managed compute? Answer in three bullets."},
    ],
    temperature=0.2,
)
print(response.choices[0].message.content)
