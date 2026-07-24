# Lab 06: Ray Serve online service

## Objectives

- Develop and test a Ray Serve application.
- Deploy it as an Anyscale Service using the provisioned Anyscale on Azure project.
- Send concurrent requests and observe replicas, logs, and latency.

## Local/Workspace test

```bash
pip install -r requirements.txt
serve run src.serve_app:deployment
python src/client.py
```

## Anyscale on Azure deployment

Use `configs/service.template.yaml` only after the instructor updates it to the schema supported by the pinned Anyscale CLI. Deploy through the approved Anyscale Service workflow. Do not deploy Kubernetes CRDs directly.

## Success criteria

The service is healthy and returns a JSON response. Optional load testing reports measured request outcomes only.
