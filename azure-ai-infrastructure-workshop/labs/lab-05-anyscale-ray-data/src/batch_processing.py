import ray
ray.init()
ds = ray.data.read_json("data/sample-prompts.jsonl")
def normalize(row):
    return {"id": row["id"], "prompt": row["prompt"].strip(), "length": len(row["prompt"].strip())}
result = ds.map(normalize)
print(result.schema())
print(result.take_all())
