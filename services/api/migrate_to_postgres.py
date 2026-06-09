"""
一次性数据迁移脚本：将 SQLite 数据导入 PostgreSQL。

用法:
    python migrate_to_postgres.py --sqlite-path ./gzus_pro.db \
        --database-url postgresql://user:pass@host:5432/dbname?sslmode=require

也可通过环境变量 DATABASE_URL 设置目标连接串；POSTGRES_URL 仅保留兼容。
"""

from __future__ import annotations

import argparse
import os
import sys
from getpass import getpass
from urllib.parse import urlsplit, urlunsplit

from sqlalchemy import create_engine, func, select, text
from sqlalchemy.orm import Session

# 确保可以从项目根目录运行
sys.path.insert(0, os.path.dirname(__file__))

from app.database import (
    Base,
    DataCache,
    EcardBinding,
    EhallSession,
    PushRegistration,
    StaffMember,
    WebPushSubscription,
)

# 迁移顺序：无外键依赖，但逻辑分组
TABLES = [
    (StaffMember, "staff_members", False),  # 字符串 PK，无序列
    (EhallSession, "ehall_sessions", True),
    (EcardBinding, "ecard_bindings", True),
    (PushRegistration, "push_registrations", True),
    (DataCache, "data_cache", True),
    (WebPushSubscription, "web_push_subscriptions", True),
]

BATCH_SIZE = 100


def _resolve_postgres_url(raw_url: str) -> str:
    if raw_url.startswith("postgres://"):
        return raw_url.replace("postgres://", "postgresql://", 1)
    if raw_url.startswith("postgresql+asyncpg://"):
        return raw_url.replace("postgresql+asyncpg://", "postgresql://", 1)
    return raw_url


def _mask_url(raw_url: str) -> str:
    parts = urlsplit(raw_url)
    if not parts.netloc:
        return "***"
    host = parts.hostname or ""
    port = f":{parts.port}" if parts.port else ""
    username = parts.username or ""
    auth = f"{username}:***@" if username else ""
    return urlunsplit((parts.scheme, f"{auth}{host}{port}", parts.path, parts.query, ""))


def _target_has_rows(dst_session: Session) -> list[tuple[str, int]]:
    rows: list[tuple[str, int]] = []
    for model, table_name, _has_sequence in TABLES:
        count = dst_session.scalar(select(func.count()).select_from(model)) or 0
        if count:
            rows.append((table_name, count))
    return rows


def _truncate_target(dst_session: Session) -> None:
    for model, _table_name, _has_sequence in reversed(TABLES):
        dst_session.execute(model.__table__.delete())
    dst_session.commit()


def _copy_table(src_session: Session, dst_session: Session, model, table_name: str) -> int:
    rows = src_session.execute(select(model)).scalars().all()
    count = 0
    batch = []
    for row in rows:
        data = {c.key: getattr(row, c.key) for c in model.__table__.columns}
        batch.append(model(**data))
        count += 1
        if len(batch) >= BATCH_SIZE:
            dst_session.add_all(batch)
            dst_session.commit()
            batch = []
    if batch:
        dst_session.add_all(batch)
        dst_session.commit()
    return count


def _reset_sequence(dst_engine, table_name: str, pk_column: str = "id") -> None:
    with dst_engine.connect() as conn:
        conn.execute(
            text(
                f"SELECT setval("
                f"pg_get_serial_sequence(:tbl, :col), "
                f"COALESCE((SELECT MAX({pk_column}) FROM {table_name}), 1)"
                f")"
            ),
            {"tbl": table_name, "col": pk_column},
        )
        conn.commit()


def migrate(sqlite_path: str, database_url: str, truncate_target: bool = False) -> None:
    src_engine = create_engine(f"sqlite:///{sqlite_path}")
    database_url = _resolve_postgres_url(database_url)
    if not database_url.startswith("postgresql://"):
        raise ValueError("目标 DATABASE_URL 必须是 PostgreSQL 连接串")

    dst_engine = create_engine(
        database_url,
        pool_size=1,
        max_overflow=2,
        pool_pre_ping=True,
    )

    # 在目标创建所有表
    Base.metadata.create_all(dst_engine)
    print("PostgreSQL 表已就绪。")

    src_session = Session(src_engine)
    dst_session = Session(dst_engine)

    existing_rows = _target_has_rows(dst_session)
    if existing_rows and not truncate_target:
        print("目标 PostgreSQL 已有数据，未执行迁移。")
        for table_name, count in existing_rows:
            print(f"  {table_name}: {count} 行")
        print("\n如确认要覆盖目标库数据，请重新运行并添加 --truncate-target --yes。")
        sys.exit(1)

    if truncate_target:
        _truncate_target(dst_session)
        print("目标表已清空。")

    summary: list[tuple[str, int, int]] = []
    errors: list[tuple[str, str]] = []

    for model, table_name, has_sequence in TABLES:
        try:
            src_count = src_session.scalar(
                select(func.count()).select_from(model)
            ) or 0
            dst_count = _copy_table(src_session, dst_session, model, table_name)
            if has_sequence and dst_count > 0:
                _reset_sequence(dst_engine, table_name)
            summary.append((table_name, src_count, dst_count))
            print(f"  {table_name}: {src_count} -> {dst_count} 行")
        except Exception as exc:
            dst_session.rollback()
            errors.append((table_name, str(exc)))
            print(f"  {table_name}: 迁移失败 - {exc}")

    src_session.close()
    dst_session.close()

    print("\n=== 迁移汇总 ===")
    print(f"{'表名':<25} {'源行数':>8} {'目标行数':>8}")
    print("-" * 45)
    for name, src, dst in summary:
        print(f"{name:<25} {src:>8} {dst:>8}")

    if errors:
        print(f"\n有 {len(errors)} 张表迁移失败:")
        for name, err in errors:
            print(f"  {name}: {err}")
        sys.exit(1)
    else:
        print("\n迁移完成。")


def main():
    parser = argparse.ArgumentParser(description="将 SQLite 数据迁移到 PostgreSQL")
    parser.add_argument(
        "--sqlite-path",
        default="./gzus_pro.db",
        help="SQLite 数据库文件路径 (默认: ./gzus_pro.db)",
    )
    parser.add_argument(
        "--database-url",
        "--postgres-url",
        dest="database_url",
        default=os.environ.get("DATABASE_URL") or os.environ.get("POSTGRES_URL", ""),
        help="PostgreSQL 连接串 (或通过 DATABASE_URL 环境变量设置)",
    )
    parser.add_argument(
        "--truncate-target",
        action="store_true",
        help="迁移前清空目标 PostgreSQL 中本应用的表",
    )
    parser.add_argument(
        "--yes",
        action="store_true",
        help="确认执行危险操作，如 --truncate-target",
    )
    args = parser.parse_args()

    if not args.database_url:
        parser.error("请提供 --database-url 或设置 DATABASE_URL 环境变量")

    if not os.path.isfile(args.sqlite_path):
        parser.error(f"SQLite 文件不存在: {args.sqlite_path}")

    if args.truncate_target and not args.yes:
        confirmation = getpass("将清空目标 PostgreSQL 表。输入 YES 确认: ")
        if confirmation != "YES":
            parser.error("未确认，已取消")

    print(f"源: SQLite ({args.sqlite_path})")
    print(f"目标: PostgreSQL ({_mask_url(args.database_url)})")
    print()
    migrate(args.sqlite_path, args.database_url, truncate_target=args.truncate_target)


if __name__ == "__main__":
    main()
