# Lab 04: Anyscale on Azure orientation

## Scope

This lab uses the Microsoft Azure first-party service **Anyscale on Azure**. The cloud and platform integration must be provisioned before the workshop. Students do not install an Anyscale Operator or build Anyscale on AKS.

## Objectives

- Identify the assigned Anyscale cloud and project.
- Validate Entra-based access through the approved sign-in experience.
- Inspect instructor-provided CPU and GPU compute configurations.
- Create or open a Workspace using the approved configuration.
- Run `ray.init()` and confirm Ray resources.
- Validate the approved Azure Blob/ACR integration if included by the instructor.

## Variables

```bash
source ../../.env
printf '%s
' "$ANYSCALE_CLOUD" "$ANYSCALE_PROJECT" "$ANYSCALE_COMPUTE_CONFIG"
```

## Access validation

Use the Anyscale on Azure user experience and CLI procedure supplied by the instructor for the provisioned environment. CLI syntax and configuration schemas must be pinned to the tested release.

Expected state:

- Assigned cloud is visible.
- Assigned project is visible.
- Approved compute configuration is selectable.
- Workspace reaches Running.
- Ray reports expected CPU resources.

## Workspace smoke test

Run `python/smoke_test.py` inside the Workspace or submit it using the approved job workflow.

## Explicitly out of scope

- Helm installation of an Anyscale Operator
- Operator identity/token parameters
- Operator values files
- AKS ingress or operator repair
- Building a standalone Anyscale-on-AKS platform

## Success criteria

A student can use the provisioned Anyscale on Azure cloud/project and execute a Ray smoke test.
