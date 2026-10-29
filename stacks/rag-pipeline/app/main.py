"""rag-api: a small retrieval-augmented generation service.

Ingests text, Markdown and PDF documents into Qdrant (embeddings from Ollama)
and answers questions with an Ollama chat model using the retrieved chunks.
All settings come from environment variables, see README.md.
"""

from __future__ import annotations

import asyncio
import hmac
import io
import logging
import os
import re
import uuid
from contextlib import asynccontextmanager
from datetime import datetime, timezone
from pathlib import PurePath
from typing import Any

import httpx
from fastapi import Depends, FastAPI, HTTPException, Request
from fastapi.responses import JSONResponse
from pydantic import BaseModel, Field, ValidationError
from pypdf import PdfReader
from pypdf.errors import PyPdfError

try:
    with open(PurePath(__file__).parent / "VERSION", encoding="utf-8") as fh:
        VERSION = fh.read().strip()
except OSError:
    VERSION = "unknown"


def env_int(name: str, default: int) -> int:
    value = os.environ.get(name, "").strip()
    return int(value) if value else default


def env_float(name: str, default: float) -> float:
    value = os.environ.get(name, "").strip()
    return float(value) if value else default


def env_bool(name: str, default: bool) -> bool:
    value = os.environ.get(name, "").strip().lower()
    if not value:
        return default
    return value in ("1", "true", "yes", "on")


class Settings:
    ollama_url = os.environ.get("OLLAMA_URL", "http://ollama:11434").rstrip("/")
    qdrant_url = os.environ.get("QDRANT_URL", "http://qdrant:6333").rstrip("/")
    qdrant_api_key = os.environ.get("QDRANT_API_KEY", "")
    collection = os.environ.get("QDRANT_COLLECTION", "documents")
    embed_model = os.environ.get("EMBED_MODEL", "nomic-embed-text:v1.5")
    chat_model = os.environ.get("CHAT_MODEL", "llama3.2:3b")
    pull_models = env_bool("PULL_MODELS", True)
    api_key = os.environ.get("RAG_API_KEY", "")
    chunk_size = env_int("CHUNK_SIZE", 1000)
    chunk_overlap = env_int("CHUNK_OVERLAP", 200)
    top_k = env_int("TOP_K", 4)
    max_upload_bytes = env_int("MAX_UPLOAD_MB", 20) * 1024 * 1024
    llm_timeout = env_float("LLM_TIMEOUT", 300.0)
    temperature = env_float("LLM_TEMPERATURE", 0.1)
    embed_batch = env_int("EMBED_BATCH_SIZE", 32)


settings = Settings()
if settings.chunk_overlap >= settings.chunk_size:
    raise SystemExit("CHUNK_OVERLAP must be smaller than CHUNK_SIZE")

logging.basicConfig(level=os.environ.get("LOG_LEVEL", "INFO").upper(),
                    format="%(asctime)s %(levelname)s %(message)s")
log = logging.getLogger("rag-api")
logging.getLogger("httpx").setLevel(logging.WARNING)

SYSTEM_PROMPT = (
    "You answer questions using only the numbered context passages provided. "
    "If the passages do not contain the answer, say that you do not know. "
    "Cite the passages you used as [1], [2], and so on. Be concise."
)


class UpstreamError(Exception):
    """Raised when Ollama or Qdrant returns an error.

    `public` is a fixed, safe status for /health; the message (which may contain
    upstream responses or internal URLs) only goes to the log.
    """

    def __init__(self, message: str, public: str = "an upstream service returned an error, see the rag-api logs"):
        super().__init__(message)
        self.public = public


class State:
    ready = False
    detail = "starting"
    vector_size: int | None = None
    client: httpx.AsyncClient | None = None


state = State()


# --------------------------------------------------------------------------
# Ollama and Qdrant helpers
# --------------------------------------------------------------------------

def http() -> httpx.AsyncClient:
    assert state.client is not None
    return state.client


def qdrant_headers() -> dict[str, str]:
    return {"api-key": settings.qdrant_api_key} if settings.qdrant_api_key else {}


async def qdrant(method: str, path: str, json: Any = None, ok404: bool = False) -> dict | None:
    resp = await http().request(method, f"{settings.qdrant_url}{path}", json=json,
                                headers=qdrant_headers(), timeout=60)
    if ok404 and resp.status_code == 404:
        return None
    if resp.status_code >= 400:
        raise UpstreamError(f"Qdrant {method} {path} returned {resp.status_code}: {resp.text[:300]}")
    return resp.json()


async def ollama(path: str, json: Any, timeout: float = 120) -> dict:
    resp = await http().post(f"{settings.ollama_url}{path}", json=json, timeout=timeout)
    if resp.status_code >= 400:
        raise UpstreamError(f"Ollama {path} returned {resp.status_code}: {resp.text[:300]}")
    return resp.json()


async def embed(texts: list[str]) -> list[list[float]]:
    vectors: list[list[float]] = []
    for i in range(0, len(texts), settings.embed_batch):
        batch = texts[i:i + settings.embed_batch]
        data = await ollama("/api/embed", {"model": settings.embed_model, "input": batch},
                            timeout=settings.llm_timeout)
        vectors.extend(data["embeddings"])
    return vectors


async def model_present(name: str) -> bool:
    resp = await http().post(f"{settings.ollama_url}/api/show", json={"model": name}, timeout=30)
    return resp.status_code == 200


async def ensure_model(name: str) -> None:
    if await model_present(name):
        return
    if not settings.pull_models:
        raise UpstreamError(f"model {name} is not available in Ollama and PULL_MODELS is off",
                            public="a configured model is missing in Ollama and PULL_MODELS is off")
    log.info("pulling model %s (first start only)", name)
    state.detail = f"pulling model {name}"
    await ollama("/api/pull", {"model": name, "stream": False}, timeout=3600)
    log.info("model %s ready", name)


async def ensure_collection() -> None:
    probe = (await embed(["dimension probe"]))[0]
    size = len(probe)
    info = await qdrant("GET", f"/collections/{settings.collection}", ok404=True)
    if info is None:
        log.info("creating collection %s (vector size %d)", settings.collection, size)
        await qdrant("PUT", f"/collections/{settings.collection}",
                     {"vectors": {"size": size, "distance": "Cosine"}})
        await qdrant("PUT", f"/collections/{settings.collection}/index?wait=true",
                     {"field_name": "source", "field_schema": "keyword"})
    else:
        existing = info["result"]["config"]["params"]["vectors"]["size"]
        if existing != size:
            raise UpstreamError(
                f"collection {settings.collection} has vector size {existing} but "
                f"{settings.embed_model} produces {size}; use another QDRANT_COLLECTION "
                "or re-create the collection",
                public="the embedding model does not match the collection's vector size, see the rag-api logs")
    state.vector_size = size


async def prepare() -> None:
    """Wait for dependencies, pull models, create the collection. Retries forever."""
    while True:
        try:
            await ensure_model(settings.embed_model)
            await ensure_model(settings.chat_model)
            await ensure_collection()
            state.ready, state.detail = True, "ok"
            log.info("ready: embed=%s chat=%s collection=%s",
                     settings.embed_model, settings.chat_model, settings.collection)
            return
        except UpstreamError as exc:
            state.detail = exc.public
            # A dimension mismatch will not fix itself; keep reporting it.
            log.warning("not ready: %s", exc)
        except (httpx.HTTPError, KeyError, ValueError) as exc:
            # The exception text can contain internal URLs: log it, do not expose it.
            state.detail = "waiting for Qdrant and Ollama"
            log.info("waiting for dependencies: %s: %s", exc.__class__.__name__, exc)
        await asyncio.sleep(5)


# --------------------------------------------------------------------------
# Text handling
# --------------------------------------------------------------------------

def split_text(text: str, size: int, overlap: int) -> list[str]:
    """Split text into chunks of at most `size` characters with `overlap`.

    Prefers to break at paragraph, line, sentence or word boundaries.
    """
    text = re.sub(r"\n{3,}", "\n\n", text.replace("\r\n", "\n").replace("\r", "\n")).strip()
    if not text:
        return []
    chunks: list[str] = []
    start = 0
    while start < len(text):
        end = min(start + size, len(text))
        if end < len(text):
            window = text[start:end]
            for sep in ("\n\n", "\n", ". ", " "):
                idx = window.rfind(sep)
                if idx > size // 2:
                    end = start + idx + len(sep)
                    break
        chunk = text[start:end].strip()
        if chunk:
            chunks.append(chunk)
        if end >= len(text):
            break
        start = max(end - overlap, start + 1)
    return chunks


def extract(filename: str, data: bytes) -> list[tuple[int | None, str]]:
    """Return (page, text) pairs for a file. Page is None for text files."""
    suffix = PurePath(filename).suffix.lower()
    if suffix in (".txt", ".md", ".markdown"):
        return [(None, data.decode("utf-8", errors="replace"))]
    if suffix == ".pdf":
        try:
            reader = PdfReader(io.BytesIO(data))
            return [(n, page.extract_text() or "") for n, page in enumerate(reader.pages, start=1)]
        except (PyPdfError, ValueError) as exc:
            raise HTTPException(422, f"{filename}: cannot read PDF ({exc})")
    raise HTTPException(415, f"{filename}: unsupported file type (use .txt, .md or .pdf)")


async def ingest_document(source: str, parts: list[tuple[int | None, str]],
                          metadata: dict[str, Any]) -> int:
    chunks: list[tuple[int | None, str]] = []
    for page, text in parts:
        chunks.extend((page, c) for c in split_text(text, settings.chunk_size, settings.chunk_overlap))
    # Replace earlier versions of the same source.
    await qdrant("POST", f"/collections/{settings.collection}/points/delete?wait=true",
                 {"filter": {"must": [{"key": "source", "match": {"value": source}}]}})
    if not chunks:
        return 0
    vectors = await embed([c for _, c in chunks])
    now = datetime.now(timezone.utc).isoformat()
    points = []
    for i, ((page, chunk), vector) in enumerate(zip(chunks, vectors)):
        payload: dict[str, Any] = {"source": source, "chunk": i, "text": chunk,
                                   "metadata": metadata, "ingested_at": now}
        if page is not None:
            payload["page"] = page
        points.append({"id": str(uuid.uuid5(uuid.NAMESPACE_URL, f"{source}#{i}")),
                       "vector": vector, "payload": payload})
    for i in range(0, len(points), 256):
        await qdrant("PUT", f"/collections/{settings.collection}/points?wait=true",
                     {"points": points[i:i + 256]})
    return len(points)


# --------------------------------------------------------------------------
# API
# --------------------------------------------------------------------------

@asynccontextmanager
async def lifespan(_: FastAPI):
    state.client = httpx.AsyncClient()
    task = asyncio.create_task(prepare())
    yield
    task.cancel()
    await state.client.aclose()


app = FastAPI(title="rag-api", version=VERSION, lifespan=lifespan)


@app.exception_handler(UpstreamError)
async def upstream_error(_: Request, exc: UpstreamError):
    # Upstream response bodies stay in the log; clients get the safe summary.
    log.warning("upstream error: %s", exc)
    return JSONResponse({"detail": exc.public}, status_code=502)


@app.exception_handler(httpx.HTTPError)
async def upstream_http_error(_: Request, exc: httpx.HTTPError):
    return JSONResponse({"detail": f"upstream request failed: {exc.__class__.__name__}"},
                        status_code=502)


def require_api_key(request: Request) -> None:
    if not settings.api_key:
        return
    supplied = request.headers.get("x-api-key", "")
    auth = request.headers.get("authorization", "")
    if not supplied and auth.lower().startswith("bearer "):
        supplied = auth[7:].strip()
    if not hmac.compare_digest(supplied.encode(), settings.api_key.encode()):
        raise HTTPException(401, "invalid or missing API key", headers={"WWW-Authenticate": "Bearer"})


def require_ready() -> None:
    if not state.ready:
        raise HTTPException(503, f"not ready: {state.detail}")


class Document(BaseModel):
    text: str = Field(min_length=1)
    source: str = Field(min_length=1, max_length=500)
    metadata: dict[str, Any] = Field(default_factory=dict)


class IngestJSON(BaseModel):
    documents: list[Document] = Field(min_length=1, max_length=1000)


class Query(BaseModel):
    question: str = Field(min_length=1, max_length=4000)
    top_k: int | None = Field(default=None, ge=1, le=20)
    source: str | None = Field(default=None, description="only search chunks of this source")


@app.get("/health")
async def health():
    body = {"status": "ok" if state.ready else "starting", "detail": state.detail,
            "version": VERSION, "embed_model": settings.embed_model,
            "chat_model": settings.chat_model, "collection": settings.collection}
    return JSONResponse(body, status_code=200 if state.ready else 503)


@app.get("/health/live")
async def live():
    return {"status": "ok"}


@app.post("/ingest", dependencies=[Depends(require_api_key), Depends(require_ready)])
async def ingest(request: Request):
    """Ingest JSON `{"documents": [{"text", "source", "metadata"}]}` or multipart files."""
    ctype = request.headers.get("content-type", "")
    results = []
    if ctype.startswith("multipart/form-data"):
        form = await request.form(max_files=100)
        files = [f for f in form.getlist("files") + form.getlist("file") if hasattr(f, "read")]
        if not files:
            raise HTTPException(400, "send files as multipart field 'files'")
        # Read and parse every file first, so a bad file does not leave a partial ingest.
        parsed = []
        for f in files:
            data = await f.read()
            if len(data) > settings.max_upload_bytes:
                raise HTTPException(413, f"{f.filename}: larger than MAX_UPLOAD_MB")
            name = PurePath(f.filename or "upload.txt").name
            parsed.append((name, extract(name, data)))
        for name, parts in parsed:
            count = await ingest_document(name, parts, {"filename": name})
            results.append({"source": name, "chunks": count})
    elif ctype.startswith("application/json"):
        raw = await request.body()
        if len(raw) > settings.max_upload_bytes:
            raise HTTPException(413, "request larger than MAX_UPLOAD_MB")
        try:
            body = IngestJSON.model_validate_json(raw)
        except ValidationError as exc:
            raise HTTPException(422, exc.errors(include_url=False, include_context=False))
        for doc in body.documents:
            count = await ingest_document(doc.source, [(None, doc.text)], doc.metadata)
            results.append({"source": doc.source, "chunks": count})
    else:
        raise HTTPException(415, "use application/json or multipart/form-data")
    return {"collection": settings.collection, "ingested": results}


@app.post("/query", dependencies=[Depends(require_api_key), Depends(require_ready)])
async def query(body: Query):
    limit = body.top_k or settings.top_k
    vector = (await embed([body.question]))[0]
    search: dict[str, Any] = {"query": vector, "limit": limit, "with_payload": True}
    if body.source:
        search["filter"] = {"must": [{"key": "source", "match": {"value": body.source}}]}
    result = await qdrant("POST", f"/collections/{settings.collection}/points/query", search)
    points = (result or {}).get("result", {}).get("points", [])
    sources = []
    for n, p in enumerate(points, start=1):
        pl = p.get("payload") or {}
        sources.append({"n": n, "source": pl.get("source"), "page": pl.get("page"),
                        "chunk": pl.get("chunk"), "score": round(p.get("score", 0.0), 4),
                        "text": pl.get("text", "")})
    if not sources:
        return {"answer": "No documents found. Ingest documents first.",
                "model": settings.chat_model, "sources": []}
    context = "\n\n".join(
        f"[{s['n']}] (source: {s['source']}{', page ' + str(s['page']) if s['page'] else ''})\n{s['text']}"
        for s in sources)
    data = await ollama("/api/chat", {
        "model": settings.chat_model,
        "stream": False,
        "options": {"temperature": settings.temperature},
        "messages": [
            {"role": "system", "content": SYSTEM_PROMPT},
            {"role": "user", "content": f"Context:\n{context}\n\nQuestion: {body.question}"},
        ],
    }, timeout=settings.llm_timeout)
    return {"answer": data.get("message", {}).get("content", "").strip(),
            "model": settings.chat_model, "sources": sources}


@app.delete("/documents", dependencies=[Depends(require_api_key), Depends(require_ready)])
async def delete_document(source: str):
    await qdrant("POST", f"/collections/{settings.collection}/points/delete?wait=true",
                 {"filter": {"must": [{"key": "source", "match": {"value": source}}]}})
    return {"deleted": source}
