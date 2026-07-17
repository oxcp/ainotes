# Copyright (c) Microsoft. All rights reserved.

import os

from agent_framework import Agent
from agent_framework.foundry import FoundryChatClient
from agent_framework_foundry_hosting import ResponsesHostServer
from azure.identity import DefaultAzureCredential
# from dotenv import load_dotenv

# Load environment variables from the .env file next to this script,
# regardless of the current working directory.
# load_dotenv()

def build_client():
    """Build the chat client for the agent.

    Two model-routing modes are supported (set MODEL_ROUTING):
      - "gateway" (default): call the model THROUGH the module-01 APIM AI gateway.
      - "direct": call the Foundry project endpoint directly.
    """
    routing = os.environ.get("MODEL_ROUTING", "gateway").strip().lower()
    model = os.environ.get("AI_MODEL_DEPLOYMENT_NAME")
    print(f"Using model: {model} with routing: {routing}")

    if routing == "direct":
        # Direct to the Foundry project endpoint. If you have registered APIM as the project AI gateway, you can call the Foundry project endpoint directly with a valid Entra token. The Foundry project endpoint will validate the token and forward to the APIM AI gateway and then enter the model deployment. 
        # The running identity needs the
        # "Azure AI User" role on the Foundry account (granted in module-01).
        from agent_framework.foundry import FoundryChatClient
        from azure.identity import DefaultAzureCredential

        return FoundryChatClient(
            project_endpoint=os.environ["FOUNDRY_PROJECT_ENDPOINT"],
            model=model,
            credential=DefaultAzureCredential(),
        )

    if routing == "gateway":
        # Through the module-01 APIM AI gateway (OpenAI Responses API). The
        # gateway validates the caller's Entra token and forwards to Foundry with its own
        # user-assigned managed identity.
        # In this workshop, the AI Gateway validate-jwt just checks if it is a valid token 
        # issued from Entra ID, and does not enforce the audience.
        from agent_framework.openai import OpenAIChatClient
        from azure.identity import DefaultAzureCredential, get_bearer_token_provider

        credential = DefaultAzureCredential()

        access_token = credential.get_token(
            "https://ai.azure.com/.default"
        ).token

        return OpenAIChatClient(
            model=model,
            base_url=f"{os.environ['APIM_GATEWAY_URL']}/openai/v1",
            api_key=access_token,
        )
        # from agent_framework.azure import AzureOpenAIChatClient
        # from azure.identity import DefaultAzureCredential, get_bearer_token_provider

        # token_provider = get_bearer_token_provider(
        #     DefaultAzureCredential(), "https://ai.azure.com/.default"
        # )
        # return AzureOpenAIChatClient(
        #     deployment_name=model,
        #     base_url=f"{os.environ['APIM_GATEWAY_URL']}/openai/v1",
        #     azure_ad_token_provider=token_provider,   # ← callable 在这里才有效
        #     # 注意：Azure 变体按 azure_endpoint + api-version 构造 URL，
        #     # 指向 APIM 网关路径时要相应调整，不如方案 A 直接。
        # )        

    raise ValueError(
        f"Unsupported MODEL_ROUTING={routing!r}; use 'gateway' or 'direct'."
    )


def main():
    agent = Agent(
        client=build_client(),
        name="maf-agent",
        instructions="You are a friendly assistant. Keep your answers brief.",
        # History will be managed by the hosting infrastructure, thus there
        # is no need to store history by the service. Learn more at:
        # https://developers.openai.com/api/reference/resources/responses/methods/create
        default_options={"store": False},
    )

    server = ResponsesHostServer(agent)
    server.run()


if __name__ == "__main__":
    main()
