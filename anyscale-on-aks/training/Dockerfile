# Containerfile for Megatron-Bridge with transformer_engine
FROM anyscale/ray:2.53.0-py312-cu128

# Install core dependencies
RUN pip install --no-cache-dir deepspeed
RUN pip install --no-cache-dir torch
RUN pip install --no-cache-dir datasets
RUN pip install --no-cache-dir transformers
