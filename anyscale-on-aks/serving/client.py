# client_streaming.py
#from urllib.parse import urljoin
from openai import OpenAI

#api_key = "FAKE_KEY"
#base_url = "http://localhost:8000"
api_key = "ijuBOWL9k6YJwhMYn44eqKYvZ_xyz7JHKzCCFG0uQgc"
base_url = "https://deploy-gpt-oss-bqhji.cld-nmdk54hi48k6x3d3.s.anyscaleuserdata.com/"
# join the base URL with the API path for OpenAI compatibility
endpoint = base_url.rstrip("/") + "/v1"

#client = OpenAI(base_url=urljoin(base_url, "v1"), api_key=api_key)
client = OpenAI(base_url=endpoint, api_key=api_key)

# Example: Complex query with thinking process
response = client.chat.completions.create(
    model="my-gpt-oss",
    #messages=[{"role": "user", "content": "How many r in strawberry"}],
    messages=[{"role": "user", "content": "今天北京天气怎么样"}],
    stream=True,
)

# Stream
for chunk in response:
    # Stream reasoning content
    if hasattr(chunk.choices[0].delta, "reasoning_content"):
        data_reasoning = chunk.choices[0].delta.reasoning_content
        if data_reasoning:
            print(data_reasoning, end="", flush=True)
    # Later, stream the final answer
    if hasattr(chunk.choices[0].delta, "content"):
        data_content = chunk.choices[0].delta.content
        if data_content:
            print(data_content, end="", flush=True)
