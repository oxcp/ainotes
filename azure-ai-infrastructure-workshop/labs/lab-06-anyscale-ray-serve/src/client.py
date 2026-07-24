import os, requests
url = os.getenv("SERVICE_URL", "http://127.0.0.1:8000/generate")
r = requests.post(url, json={"prompt":"Explain managed Ray in one sentence."}, timeout=30)
r.raise_for_status(); print(r.json())
