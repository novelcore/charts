# compose-and-validate step image (PRD-HPC-1461 D-80). Owned by the chart and built by ml-ci-build with
# the app's config/ folder as the ONLY build context: an app carries no Dockerfile, no kubecore/ and no
# steps/compose_and_validate/ for it. The rendered WorkflowTemplate carries the command and args
# (python -I -m kaos_engine.compose, outputs params and data-lock); this image only supplies the engine,
# the app's config tree, and the kaos-lib the step images get (the same KAOS_LIB_PACKAGE build-arg).
ARG ENGINE_IMAGE
FROM ${ENGINE_IMAGE}
ARG ENGINE_VERSION
ARG ENGINE_PROFILE
ARG KAOS_LIB_PACKAGE
USER root
# The engine image ships no constraints file: freeze what it has, so the install cannot move an engine library.
RUN pip freeze --exclude-editable > /tmp/engine-constraints.txt \
 && if [ -n "${KAOS_LIB_PACKAGE}" ]; then pip install --no-cache-dir --no-deps -c /tmp/engine-constraints.txt "${KAOS_LIB_PACKAGE}"; fi \
 && rm -f /tmp/engine-constraints.txt
ENV KUBECORE_SCHEMA_PROFILE=${ENGINE_PROFILE} KUBECORE_CONFIG_DIR=/work/config
COPY . /work/config/
LABEL io.kaos.engine=${ENGINE_VERSION}
USER 65532:65532
