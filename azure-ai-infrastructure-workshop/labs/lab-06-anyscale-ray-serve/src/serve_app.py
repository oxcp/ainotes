from fastapi import FastAPI
from pydantic import BaseModel
from ray import serve
app = FastAPI()
class Body(BaseModel):
    prompt: str
@serve.deployment(num_replicas=1, ray_actor_options={"num_cpus": 1})
@serve.ingress(app)
class WorkshopService:
    @app.post("/generate")
    async def generate(self, body: Body):
        return {"response": f"Processed prompt: {body.prompt}"}
deployment = WorkshopService.bind()
