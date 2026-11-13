from pathlib import Path
from kubecore.authoring import artifact, dataset, model, pipeline, step
with pipeline("ml-pipeline") as p:
    load = step("dataset-loading", kind="ingest", inputs=["dataset"], produces=[dataset("loaded")])
    hello = step("hello-world", kind="transform", reads=["experiment"], inputs=["dataset"], needs=[load],
                 produces=[artifact("report")])
    train = step("train", kind="train", reads=["model", "optim"], needs=[load], gpu=True, when="optim == sgd and model != large",
                 checkpoint_every="20m", walltime="12h", produces=[model("m")])
    ev = step("evaluate", kind="evaluate", needs=[train], matrix={"seed": [1, 2]})
if __name__ == "__main__":
    p.write(Path(__file__).parent / "out" / "raw-workflow-template.yaml")
