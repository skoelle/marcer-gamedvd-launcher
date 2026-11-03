# Copyright (c) 2026 Stefan Koelle (https://stefankoelle.de)
# Licensed under the MIT License. See LICENSE file in project root for details.
FROM python:3.12-slim

ENV PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    PIP_NO_CACHE_DIR=1 \
    HOME=/tmp

RUN apt-get update \
    && apt-get install -y --no-install-recommends tzdata \
    && rm -rf /var/lib/apt/lists/*

RUN python -m venv /opt/venv
ENV PATH="/opt/venv/bin:$PATH"
RUN /opt/venv/bin/pip install --no-cache-dir olefile==0.47

WORKDIR /app

COPY LICENSE /app/LICENSE
COPY tools /app/tools

# The image runs as a non-root user. Compose can override this with
# PUID/PGID to match the host's NAS permissions.
USER 10001:10001

EXPOSE 8080 8764

CMD ["python", "tools/catalog-pipeline/pipeline.py", "serve"]
