import os
from openai import OpenAI
client = OpenAI(base_url=os.environ["MODEL_BASE_URL"], api_key="not-required")
response = client.chat.completions.create(
    model=os.environ["MODEL_NAME"],
    messages=[
        {"role": "system", "content": "You are an Azure AI infrastructure assistant."},
        {"role": "user", "content": "Explain inference versus fine-tuning in three bullets."},
    ],
    temperature=0.2,
)
print(response.choices[0].message.content)
