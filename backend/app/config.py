from functools import lru_cache
from pathlib import Path

from pydantic_settings import BaseSettings, SettingsConfigDict

# Resolve repo root (.env lives there, not in backend/) regardless of CWD.
_REPO_ROOT = Path(__file__).resolve().parents[2]


class Settings(BaseSettings):
    model_config = SettingsConfigDict(
        env_file=(_REPO_ROOT / ".env", _REPO_ROOT / ".env.local"),
        env_file_encoding="utf-8",
        extra="ignore",
    )

    postgres_host: str = "localhost"
    postgres_port: int = 5432
    postgres_db: str = "restaurant_ordering"

    # Migration/ops role — superuser. Not used by the pool.
    postgres_user: str = "ros_admin"
    postgres_password: str = ""

    # Least-privilege role the FastAPI pool connects as, so RLS is enforced.
    # Falls back to postgres_user for local dev before 11_roles_grants.sql runs.
    app_db_user: str = ""
    app_db_password: str = ""

    jwt_secret: str = "change-me-in-prod"
    jwt_algorithm: str = "HS256"
    jwt_expire_minutes: int = 1440

    cors_origins: str = "http://localhost:3000,http://127.0.0.1:3000"

    pool_min_size: int = 2
    pool_max_size: int = 10

    @property
    def cors_origins_list(self) -> list[str]:
        return [o.strip() for o in self.cors_origins.split(",") if o.strip()]

    @property
    def dsn(self) -> str:
        user = self.app_db_user or self.postgres_user
        password = self.app_db_password or self.postgres_password
        parts = [
            f"host={self.postgres_host}",
            f"port={self.postgres_port}",
            f"user={user}",
            f"dbname={self.postgres_db}",
        ]
        if password:
            parts.append(f"password={password}")
        return " ".join(parts)


@lru_cache
def get_settings() -> Settings:
    return Settings()
