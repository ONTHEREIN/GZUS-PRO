from __future__ import annotations

import math
from collections.abc import Mapping
from datetime import date, datetime
from zoneinfo import ZoneInfo

from sqlalchemy.orm import Session

from app.database import EcardWaterBalanceSnapshot

SHANGHAI = ZoneInfo("Asia/Shanghai")
WATER_TYPES = (
    ("cold_water", "coldWaterBalance", "coldWaterUnit", "吨"),
    ("hot_water", "hotWaterBalance", "hotWaterUnit", "元"),
)


def _numeric_balance(value: object) -> float | None:
    if isinstance(value, bool):
        return None
    try:
        result = float(value)
    except (TypeError, ValueError):
        return None
    return result if math.isfinite(result) else None


def record_water_balance_snapshots(
    db: Session,
    room_id: str,
    summary: Mapping[str, object],
    captured_at: datetime,
) -> None:
    """写入当天最新冷热水余额；非数值余额不会生成历史记录。"""
    snapshot_date = captured_at.astimezone(SHANGHAI).date()
    for utility_type, balance_key, unit_key, default_unit in WATER_TYPES:
        balance = _numeric_balance(summary.get(balance_key))
        if balance is None:
            continue
        unit = str(summary.get(unit_key) or default_unit)
        snapshot = (
            db.query(EcardWaterBalanceSnapshot)
            .filter(
                EcardWaterBalanceSnapshot.room_id == room_id,
                EcardWaterBalanceSnapshot.utility_type == utility_type,
                EcardWaterBalanceSnapshot.snapshot_date == snapshot_date,
            )
            .first()
        )
        if snapshot is None:
            snapshot = EcardWaterBalanceSnapshot(
                room_id=room_id,
                utility_type=utility_type,
                snapshot_date=snapshot_date,
                balance=balance,
                unit=unit,
                captured_at=captured_at,
            )
            db.add(snapshot)
        else:
            snapshot.balance = balance
            snapshot.unit = unit
            snapshot.captured_at = captured_at


def monthly_water_overviews(
    snapshots: list[EcardWaterBalanceSnapshot],
) -> list[dict[str, object]]:
    """按月计算余额趋势与基于快照的消耗/充值估算。"""
    ordered = sorted(snapshots, key=lambda item: (item.snapshot_date, item.captured_at))
    by_month: dict[str, list[EcardWaterBalanceSnapshot]] = {}
    for snapshot in ordered:
        month = snapshot.snapshot_date.strftime("%Y-%m")
        by_month.setdefault(month, []).append(snapshot)

    result: list[dict[str, object]] = []
    previous: EcardWaterBalanceSnapshot | None = None
    for month in sorted(by_month):
        month_snapshots = by_month[month]
        usage = 0.0
        recharge = 0.0
        peak_usage = 0.0
        peak_date: date | None = None
        for snapshot in month_snapshots:
            if previous is not None:
                delta = previous.balance - snapshot.balance
                if delta > 0:
                    usage += delta
                    if delta > peak_usage:
                        peak_usage = delta
                        peak_date = snapshot.snapshot_date
                elif delta < 0:
                    recharge += -delta
            previous = snapshot
        first = month_snapshots[0]
        last = month_snapshots[-1]
        result.append(
            {
                "month": month,
                "recordedDays": len(month_snapshots),
                "openingBalance": first.balance,
                "closingBalance": last.balance,
                "estimatedUsage": usage,
                "estimatedRecharge": recharge,
                "averageDailyUsage": usage / len(month_snapshots),
                "peakDate": peak_date.isoformat() if peak_date else None,
                "peakUsage": peak_usage,
                "unit": last.unit,
                "cachedAt": last.captured_at.isoformat(),
            }
        )
    return list(reversed(result))
