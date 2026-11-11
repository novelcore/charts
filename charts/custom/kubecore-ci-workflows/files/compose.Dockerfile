# compose-and-validate step image (PRD-HPC-1461 D-80). Owned by the chart and built by ml-ci-build with
# the app's config/ folder as the ONLY build context: an app carries no Dockerfile, no kubecore/ and no
# steps/compose_and_validate/ for it. The rendered WorkflowTemplate carries the command and args
# (python -I -m kaos_engine.compose, outputs params, data-lock and dataset-pin); this image only supplies the engine,
# the app's config tree, and the kaos-lib the step images get (the same KAOS_LIB_PACKAGE build-arg).
ARG ENGINE_IMAGE
FROM ${ENGINE_IMAGE}
ARG ENGINE_VERSION
ARG ENGINE_PROFILE
ARG KAOS_LIB_PACKAGE
USER root
# kaos-lib resolves the run's data in this step. Only kaos-lib itself is added: every library it needs is
# already in the engine image, pinned and scanned with the engine (/etc/kaos-engine/constraints.txt), so an
# app's build never pulls an unpinned library. The import line proves it at build time: a kaos-lib that needs
# something the engine image lacks fails the build here, not the first run.
RUN test -f /etc/kaos-engine/constraints.txt \
 && if [ -n "${KAOS_LIB_PACKAGE}" ]; then \
      pip install --no-cache-dir --no-deps -c /etc/kaos-engine/constraints.txt "${KAOS_LIB_PACKAGE}" \
   && python -I -c "import kaos_lib.datasets, kaos_lib.lock, kaos_lib.lakefs, kaos_lib.zitadel, jwt, cryptography"; \
    fi
ENV KUBECORE_SCHEMA_PROFILE=${ENGINE_PROFILE} KUBECORE_CONFIG_DIR=/work/config
COPY . /work/config/
LABEL io.kaos.engine=${ENGINE_VERSION}
USER 65532:65532
