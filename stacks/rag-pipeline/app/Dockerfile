# rag-api: published as ghcr.io/aisolutionscamp/rag-api:<VERSION>
FROM python:3.14.9-slim-trixie

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PIP_NO_CACHE_DIR=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1

WORKDIR /app
COPY requirements.txt .
RUN pip install --no-deps -r requirements.txt \
 && useradd --system --uid 10001 --no-create-home --shell /usr/sbin/nologin rag

COPY VERSION main.py ./

USER 10001
EXPOSE 8000

# /health returns 503 until Ollama has the models and the Qdrant collection exists.
# The first start pulls the models, hence the long start period.
HEALTHCHECK --interval=10s --timeout=5s --start-period=20m --start-interval=5s --retries=3 \
  CMD ["python", "-c", "import urllib.request; urllib.request.urlopen('http://127.0.0.1:8000/health', timeout=4)"]

CMD ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8000", "--no-server-header"]
