from pathlib import Path
from kubecore.authoring import artifact, dataset, model, pipeline, step
HERE = Path(__file__).parent
with pipeline("ml-pipeline") as p:
    prep = step("prep", kind="transform", produces=[dataset("cleaned")], walltime="1h")
    train = step("train", kind="train", needs=[prep], produces=[model("champion")], matrix={"seed": [1, 2, 3]}, matrix_allow_failed=True, walltime="2h")
    rep = step("report", kind="transform", needs=[prep, train], produces=[artifact("summary")], when="prep.ok == true")
if __name__ == "__main__":
    p.write(HERE / "out" / "raw-workflow-template.yaml")
