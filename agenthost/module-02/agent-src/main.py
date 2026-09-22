# Copyright (c) Microsoft. All rights reserved.

import asyncio
import os

from agent_framework import Agent
from agent_framework.openai import OpenAIChatClient
from agent_framework_foundry_hosting import ResponsesHostServer
from azure.identity import DefaultAzureCredential

from analysis_workflow import (
    BusinessAnalysisWorkflow,
    HorizonDBRepository,
    OpenAIResponsesModel,
)


_workflow = None
_initialization_lock = asyncio.Lock()


async def _get_workflow() -> BusinessAnalysisWorkflow:
    global _workflow
    if _workflow is not None:
        return _workflow
    async with _initialization_lock:
        if _workflow is None:
            repository = HorizonDBRepository(os.environ.get("WRITE_DATABASE_URL", ""))
            await repository.open()
            model = OpenAIResponsesModel("APIM_GATEWAY_URL", "AI_MODEL_DEPLOYMENT_NAME")
            _workflow = BusinessAnalysisWorkflow(model, repository)
    return _workflow


async def run_business_analysis(requirement: str, business_data: str) -> dict[str, str]:
    """Run reader, writer, reviewer, and writer revision over supplied business data."""
    result = await (await _get_workflow()).run(requirement, business_data)
    return {
        "analysis_id": result["analysis_id"],
        "final_report": result["final_report"],
    }


def build_client() -> OpenAIChatClient:
    endpoint = os.environ["APIM_GATEWAY_URL"].rstrip("/")
    model = os.environ.get("AI_MODEL_DEPLOYMENT_NAME", "gpt-5.4-mini")
    credential = DefaultAzureCredential()
    access_token = credential.get_token("https://ai.azure.com/.default").token
    return OpenAIChatClient(
        model=model,
        base_url=f"{endpoint}/openai/v1",
        api_key=access_token,
    )


def main() -> None:
    coordinator = Agent(
        client=build_client(),
        name="business-analysis-coordinator",
        instructions=(
            "Collect an analysis requirement and the source business data. When both are "
            "available, call run_business_analysis exactly once. Present its final_report "
            "and analysis_id. Do not perform the analysis yourself."
        ),
        tools=[run_business_analysis],
        default_options={"store": False},
    )
    ResponsesHostServer(coordinator).run()


if __name__ == "__main__":
    main()
