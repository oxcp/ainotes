import os
from openai import OpenAI
client = OpenAI(base_url=os.environ["MODEL_BASE_URL"], api_key="not-required")
stream = client.chat.completions.create(model=os.environ["MODEL_NAME"], messages=[{"role":"user","content":"Give a GPU troubleshooting checklist."}], stream=True)
for event in stream:
    text = event.choices[0].delta.content
    if text: print(text, end="", flush=True)
print()
