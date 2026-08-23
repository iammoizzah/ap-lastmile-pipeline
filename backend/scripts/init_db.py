"""
Creates all tables defined in app/models/models.py.

MVP uses create_all() for speed. Swap to Alembic migrations before this
goes anywhere near a real environment with data you care about.

Usage:
    cd backend
    python scripts/init_db.py
"""
import sys
import os

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

from app.database import Base, engine
from app.models import models  # noqa: F401  (import registers models with Base)


def main():
    print(f"Creating tables at {engine.url} ...")
    Base.metadata.create_all(bind=engine)
    print("Done. Tables created:")
    for table in Base.metadata.sorted_tables:
        print(f"  - {table.name}")


if __name__ == "__main__":
    main()

