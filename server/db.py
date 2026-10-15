import os

from sqlalchemy import create_engine
from sqlalchemy.engine import URL as SQLAlchemyURL
from sqlalchemy.orm import DeclarativeBase, Session, sessionmaker


def _build_database_url() -> str:
    host = os.environ.get("POSTGRES_HOST", "postgres")
    port = int(os.environ.get("POSTGRES_PORT", "5432"))
    user = os.environ.get("POSTGRES_USER", "postgres")
    password = os.environ.get("POSTGRES_PASSWORD", "postgres")
    db = os.environ.get("APP_DB_NAME", "mem0_app")
    # Neon rejects plaintext connections ("connection is insecure"); default to
    # require. Local dev against a plain compose Postgres sets disable.
    sslmode = os.environ.get("POSTGRES_SSLMODE", "require")
    # URL.create percent-encodes credentials, so passwords with @:/#% are safe.
    return SQLAlchemyURL.create(
        "postgresql+psycopg",
        username=user,
        password=password,
        host=host,
        port=port,
        database=db,
        query={"sslmode": sslmode},
    ).render_as_string(hide_password=False)


engine = create_engine(_build_database_url(), pool_pre_ping=True)

SessionLocal = sessionmaker(bind=engine, autoflush=False, expire_on_commit=False)


class Base(DeclarativeBase):
    pass


def get_db():
    """FastAPI dependency that yields a SQLAlchemy session."""
    db: Session = SessionLocal()
    try:
        yield db
    finally:
        db.close()
