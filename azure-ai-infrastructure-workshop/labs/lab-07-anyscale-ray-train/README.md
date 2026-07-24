# Lab 07: Ray Train pattern

This guided lab focuses on distributed execution mechanics before introducing a model-specific LoRA/QLoRA implementation.

## Steps

1. Run `src/train_skeleton.py` with an approved CPU configuration to validate workers.
2. Update the pinned compute configuration for approved GPU workers.
3. Replace the TODO block with the instructor-validated model, dataset, dependency set, and checkpoint location.
4. Run a small number of steps.
5. Inspect worker count, metrics, and checkpoint output.

Model licenses, Hugging Face access, GPU memory, CUDA/PyTorch compatibility, dataset format, NCCL, and storage permissions must be validated before enabling the GPU extension.
