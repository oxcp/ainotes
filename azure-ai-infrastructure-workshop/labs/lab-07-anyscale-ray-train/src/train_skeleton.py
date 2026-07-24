from ray.train import ScalingConfig
from ray.train.torch import TorchTrainer

def train_loop(config):
    import os
    from ray import train
    context = train.get_context()
    train.report({"world_rank": context.get_world_rank(), "learning_rate": config["learning_rate"]})
    # TODO: instructor-validated model, PEFT setup, dataset, training steps, checkpoint.

trainer = TorchTrainer(
    train_loop_per_worker=train_loop,
    train_loop_config={"learning_rate": 2e-4},
    scaling_config=ScalingConfig(num_workers=2, use_gpu=False),
)
print(trainer.fit())
