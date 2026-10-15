FROM python:3.12-slim

WORKDIR /app

COPY requirements.txt .

RUN pip install --no-cache-dir -r requirements.txt

COPY . .

EXPOSE 8000

ENV PYTHONUNBUFFERED=1

# mem0's history SQLite defaults to /app/history/history.db; production has no
# compose-style ./history bind mount, so create the directory up front.
RUN mkdir -p /app/history

# Apply pending app-database migrations, then serve on $PORT
# (Render sets PORT, default 10000; falls back to 8000 for local runs).
CMD ["sh", "-c", "alembic upgrade head && exec uvicorn main:app --host 0.0.0.0 --port ${PORT:-8000}"]
