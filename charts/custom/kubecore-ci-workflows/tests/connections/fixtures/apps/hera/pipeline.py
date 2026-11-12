"""Fixture app in the shape of the hera template, on the step contract (PRD novelcore/kaos#1911).

The chart's own stand-in: tests/connections renders it with the platform pipeline engine (harness.py
write-raw) into fixtures/hera-raw/hera-app.yaml. It is not the template and is never built or run.
"""

from pathlib import Path

from kubecore.authoring import artifact, pipeline, step

HERE = Path(__file__).parent

with pipeline("ml-pipeline") as p:
    hello = step("hello-world", kind="transform", reads=["experiment"], inputs=["dataset"],
                 produces=[artifact("report")])

if __name__ == "__main__":
    p.write(HERE / "out" / "raw-workflow-template.yaml")
