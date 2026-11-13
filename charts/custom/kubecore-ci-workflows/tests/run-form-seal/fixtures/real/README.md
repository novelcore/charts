Real engine output (kaos-hpc-operator branch feature/1533-f21-seal-hooks at 297686b, venv python 3.13), taken
after `kaos_engine.render`, `kubecore.enhance --form-data`, `engine.py stamp` and `engine.py steps`, with the
engine's local-dev pipeline context (namespace ns-a, HPC enabled), engine version 0.9.9:
  tests-app     the engine's tests/app, unchanged (has a dataset input)
  extended-app  Hydra groups, a gpu step with when=, walltime 12h, checkpoint_every, a matrix step, a credential-like leaf
  pinned-step   extended-app with hello-world pinned through the compute-class annotation
pipeline.py is the app that produced each. No hand edits.
  input-in-group-option  tests-app without config/dataset.yaml; a Hydra group option (@package _global_) supplies the dataset input, so the raw form has leafOptions for an input (engine 68b1bb6)
