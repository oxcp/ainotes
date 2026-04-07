import requests

# Service specific config
base_url = "https://deploy-gpt-oss-bqhji.cld-nmdk54hi48k6x3d3.s.anyscaleuserdata.com"
token = "ijuBOWL9k6YJwhMYn44eqKYvZ_xyz7JHKzCCFG0uQgc"

# Requests config
path = "/"
full_url = f"{base_url}{path}"
headers = {
    "Authorization": f"Bearer {token}",
    "X-ANYSCALE-VERSION": "v-3y3myzo1vp"
}

resp = requests.get(full_url, headers=headers)

print(resp.text)