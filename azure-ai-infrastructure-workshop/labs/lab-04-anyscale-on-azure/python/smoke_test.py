import json
import ray
ray.init()
print(json.dumps(ray.cluster_resources(), indent=2, sort_keys=True))
@ray.remote
def hello():
    return "Hello from Anyscale on Azure"
print(ray.get(hello.remote()))
