"""Fixture app in the shape of the yolo template, on the step contract (PRD novelcore/kaos#1911).

The chart's own stand-in: tests/connections renders it with the platform pipeline engine (harness.py
write-raw) into fixtures/hera-raw/yolo-app.yaml. It is not the template and is never built or run. It has
what the suite needs of a real pipeline: GPU steps, a step with an HPC run limit, conditions, two inputs
under different names, and a produced dataset, model and artifact.
"""

from pathlib import Path

from kubecore.authoring import artifact, dataset, model, pipeline, step

HERE = Path(__file__).parent

with pipeline("ml-pipeline") as p:
    validate = step("config-validation", kind="control", reads=["data", "model", "train"])
    prepare = step("prepare-data", kind="transform", needs=[validate], reads=["data"], inputs=["dataset"],
                   produces=[dataset("prepared")])
    train = step("model-training", kind="train", gpu=True, needs=[prepare], walltime="12h",
                 reads=["experiment", "data", "model", "train", "image_processing", "logging"],
                 produces=[model("checkpoints")])
    qat = step("qat-finetune", kind="train", gpu=True, needs=[train],
               reads=["experiment", "train", "quantization"],
               when="{{workflow.parameters.quantization-mode}} == qat",
               produces=[model("qat")])
    quant = step("model-quantization", kind="transform", needs=[train, qat],
                 reads=["experiment", "quantization"], inputs=["calibration"],
                 when="{{workflow.parameters.quantization-mode}} != none",
                 produces=[artifact("quantized")])
    register = step("model-registration", kind="publish", needs=[train, quant],
                    reads=["data", "model", "registration"])

if __name__ == "__main__":
    p.write(HERE / "out" / "raw-workflow-template.yaml")
