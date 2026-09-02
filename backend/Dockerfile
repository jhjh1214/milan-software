# One image, one process. No build stage is needed: psycopg is installed from
# the binary wheel, so nothing here compiles.
FROM python:3.12-slim

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PIP_NO_CACHE_DIR=1

WORKDIR /srv

# Dependencies first, so a code change does not reinstall them. Pinned, per
# CLAUDE.md -- an unpinned rebuild months from now is a different application.
COPY requirements.txt ./
RUN pip install --no-cache-dir -r requirements.txt

COPY alembic.ini ./
COPY migrations ./migrations
COPY app ./app

# Not root. A container that only serves HTTP has no reason to be able to
# rewrite its own code.
RUN adduser --system --group --no-create-home milan \
    && chown -R milan:milan /srv
USER milan

EXPOSE 8000

# No curl in the slim image, and adding one for a health check is a poor
# trade. Python is already here.
HEALTHCHECK --interval=30s --timeout=5s --start-period=20s --retries=3 \
    CMD ["python", "-c", "import urllib.request; urllib.request.urlopen('http://127.0.0.1:8000/api/health').read()"]

# Migrate, then serve. Safe because there is exactly one replica by design
# (CLAUDE.md: one node, no Kubernetes) -- with several, two containers would
# race for the Alembic lock on every deploy.
#
# One worker: the load is a handful of phones and one dashboard, and a single
# process keeps the logs and the failure modes legible.
CMD ["sh", "-c", "alembic upgrade head && exec uvicorn app.main:app --host 0.0.0.0 --port 8000 --workers 1 --proxy-headers --forwarded-allow-ips='*'"]
