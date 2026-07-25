from __future__ import annotations

import hashlib
import os
from datetime import (
    datetime,
    timedelta,
    timezone,
)
from typing import Any

from google.cloud import firestore
from pydantic import (
    BaseModel,
    ConfigDict,
    Field,
)

from agent_runtime import (
    AgentRuntime,
    stable_id,
)


class ObservedFinding(BaseModel):
    model_config = ConfigDict(
        extra="allow"
    )

    schema_version: str = "1.0"
    observation_id: str
    finding_id: str
    observed_at: str
    entity_key: str
    signal_type: str
    risk_weight: int
    disposition: str
    severity: str

    finding: dict[str, Any] = (
        Field(default_factory=dict)
    )


PROJECT_ID = os.environ[
    "PROJECT_ID"
]

FIRESTORE_DATABASE = (
    os.environ.get(
        "FIRESTORE_DATABASE",
        "(default)",
    )
)

CORRELATION_COLLECTION = (
    os.environ.get(
        "CORRELATION_COLLECTION",
        "correlation_windows",
    )
)

CORRELATION_WINDOW_MINUTES = int(
    os.environ.get(
        "CORRELATION_WINDOW_MINUTES",
        "15",
    )
)

MIN_SIGNALS = int(
    os.environ.get(
        "MIN_SIGNALS",
        "2",
    )
)

INCIDENT_SCORE_THRESHOLD = int(
    os.environ.get(
        "INCIDENT_SCORE_THRESHOLD",
        "40",
    )
)

MAX_SIGNALS_PER_WINDOW = int(
    os.environ.get(
        "MAX_SIGNALS_PER_WINDOW",
        "25",
    )
)

STATE_TTL_DAYS = int(
    os.environ.get(
        "STATE_TTL_DAYS",
        "7",
    )
)

firestore_client = firestore.Client(
    project=PROJECT_ID,
    database=FIRESTORE_DATABASE,
)

SEVERITY_RANK = {
    "UNKNOWN": 0,
    "INFORMATIONAL": 1,
    "LOW": 2,
    "MEDIUM": 3,
    "HIGH": 4,
    "CRITICAL": 5,
}


def utc_now_dt() -> datetime:
    return datetime.now(timezone.utc)


def to_iso(
    value: datetime,
) -> str:
    return (
        value.isoformat()
        .replace("+00:00", "Z")
    )


def parse_time(
    value: Any,
) -> datetime | None:
    if isinstance(
        value,
        datetime,
    ):
        return (
            value
            if value.tzinfo
            else value.replace(
                tzinfo=timezone.utc
            )
        )

    if (
        isinstance(value, str)
        and value
    ):
        try:
            return datetime.fromisoformat(
                value.replace(
                    "Z",
                    "+00:00",
                )
            )

        except ValueError:
            return None

    return None


def risk_level(
    score: int,
) -> str:
    if score >= 80:
        return "CRITICAL"

    if score >= 50:
        return "HIGH"

    if score >= 25:
        return "MEDIUM"

    return "LOW"


def compact_signal(
    observation: ObservedFinding,
) -> dict[str, Any]:
    finding = observation.finding

    return {
        "observation_id": (
            observation.observation_id
        ),
        "finding_id": (
            observation.finding_id
        ),
        "observed_at": (
            observation.observed_at
        ),
        "source": str(
            finding.get(
                "source",
                "unknown",
            )
        ),
        "category": str(
            finding.get(
                "category",
                "unknown",
            )
        ),
        "severity": (
            observation.severity
        ),
        "signal_type": (
            observation.signal_type
        ),
        "risk_weight": (
            observation.risk_weight
        ),
        "title": str(
            finding.get(
                "title",
                "",
            )
        )[:300],
        "description": str(
            finding.get(
                "description",
                "",
            )
        )[:1200],
        "asset": finding.get(
            "asset",
            {},
        ),
        "evidence": finding.get(
            "evidence",
            {},
        ),
    }


def window_document_id(
    entity_key: str,
) -> str:
    return hashlib.sha256(
        entity_key.encode("utf-8")
    ).hexdigest()


@firestore.transactional
def update_correlation_window(
    transaction: (
        firestore.Transaction
    ),
    document_ref: (
        firestore.DocumentReference
    ),
    observation: ObservedFinding,
) -> dict[str, Any] | None:
    snapshot = document_ref.get(
        transaction=transaction
    )

    existing = (
        snapshot.to_dict()
        if snapshot.exists
        else {}
    )

    now_dt = utc_now_dt()

    window_started_at = parse_time(
        existing.get(
            "window_started_at"
        )
    )

    expired = (
        window_started_at is None
        or (
            now_dt
            - window_started_at
        )
        > timedelta(
            minutes=(
                CORRELATION_WINDOW_MINUTES
            )
        )
    )

    if expired:
        window_started_at = now_dt

        signals: list[
            dict[str, Any]
        ] = []

        seen_observation_ids: list[
            str
        ] = []

        last_published_rank = 0
        revision = 0

    else:
        signals = list(
            existing.get(
                "signals",
                [],
            )
        )

        seen_observation_ids = list(
            existing.get(
                "seen_observation_ids",
                [],
            )
        )

        last_published_rank = int(
            existing.get(
                "last_published_rank",
                0,
            )
        )

        revision = int(
            existing.get(
                "revision",
                0,
            )
        )

    if (
        observation.observation_id
        in seen_observation_ids
    ):
        return None

    signals.append(
        compact_signal(observation)
    )

    signals = signals[
        -MAX_SIGNALS_PER_WINDOW:
    ]

    seen_observation_ids.append(
        observation.observation_id
    )

    seen_observation_ids = (
        seen_observation_ids[
            -MAX_SIGNALS_PER_WINDOW:
        ]
    )

    sources = sorted(
        {
            str(
                item.get(
                    "source",
                    "unknown",
                )
            )
            for item in signals
        }
    )

    categories = sorted(
        {
            str(
                item.get(
                    "category",
                    "unknown",
                )
            )
            for item in signals
        }
    )

    signal_types = sorted(
        {
            str(
                item.get(
                    "signal_type",
                    "unknown",
                )
            )
            for item in signals
        }
    )

    base_score = sum(
        int(
            item.get(
                "risk_weight",
                0,
            )
        )
        for item in signals
    )

    cross_source_bonus = (
        12
        if len(sources) >= 2
        else 0
    )

    repeated_signal_bonus = min(
        12,
        max(
            0,
            len(signals) - 1,
        )
        * 3,
    )

    category_diversity_bonus = min(
        8,
        max(
            0,
            len(categories) - 1,
        )
        * 4,
    )

    score = min(
        100,
        base_score
        + cross_source_bonus
        + repeated_signal_bonus
        + category_diversity_bonus,
    )

    level = risk_level(score)

    current_rank = (
        SEVERITY_RANK[level]
    )

    has_critical_signal = any(
        str(
            item.get(
                "severity",
                "",
            )
        ).upper()
        == "CRITICAL"
        for item in signals
    )

    threshold_met = (
        score
        >= INCIDENT_SCORE_THRESHOLD
    )

    enough_signals = (
        len(signals)
        >= MIN_SIGNALS
    )

    publish_incident = (
        (
            has_critical_signal
            or (
                threshold_met
                and enough_signals
            )
        )
        and (
            current_rank
            > last_published_rank
        )
    )

    incident_id = stable_id(
        "incident",
        observation.entity_key,
        to_iso(window_started_at),
    )

    if publish_incident:
        revision += 1

        last_published_rank = (
            current_rank
        )

    state = {
        "entity_key": (
            observation.entity_key
        ),
        "window_started_at": (
            window_started_at
        ),
        "last_seen_at": now_dt,
        "expires_at": (
            now_dt
            + timedelta(
                days=STATE_TTL_DAYS
            )
        ),
        "signals": signals,
        "seen_observation_ids": (
            seen_observation_ids
        ),
        "sources": sources,
        "categories": categories,
        "signal_types": signal_types,
        "risk_score": score,
        "risk_level": level,
        "last_published_rank": (
            last_published_rank
        ),
        "revision": revision,
        "incident_id": incident_id,
    }

    transaction.set(
        document_ref,
        state,
    )

    if not publish_incident:
        return None

    return {
        "schema_version": "1.0",
        "event_type": (
            "correlated-security-incident"
        ),
        "source": "correlation-agent",
        "severity": level,
        "incident_id": incident_id,
        "incident_revision": revision,
        "created_at": to_iso(now_dt),
        "window_started_at": to_iso(
            window_started_at
        ),
        "window_minutes": (
            CORRELATION_WINDOW_MINUTES
        ),
        "entity_key": (
            observation.entity_key
        ),
        "risk_score": score,
        "risk_level": level,
        "signal_count": len(signals),
        "sources": sources,
        "categories": categories,
        "signal_types": signal_types,
        "correlation_factors": {
            "base_score": base_score,
            "cross_source_bonus": (
                cross_source_bonus
            ),
            "repeated_signal_bonus": (
                repeated_signal_bonus
            ),
            "category_diversity_bonus": (
                category_diversity_bonus
            ),
            "critical_signal_present": (
                has_critical_signal
            ),
        },
        "signals": signals,
    }


def process(
    payload: dict[str, Any],
    _attributes: dict[str, str],
    _input_message_id: str,
) -> list[dict[str, Any]]:
    observation = (
        ObservedFinding
        .model_validate(payload)
    )

    document_ref = (
        firestore_client
        .collection(
            CORRELATION_COLLECTION
        )
        .document(
            window_document_id(
                observation.entity_key
            )
        )
    )

    transaction = (
        firestore_client.transaction(
            max_attempts=5
        )
    )

    incident = (
        update_correlation_window(
            transaction,
            document_ref,
            observation,
        )
    )

    return (
        [incident]
        if incident
        else []
    )


def main() -> None:
    AgentRuntime(
        agent_name=(
            "correlation-agent"
        ),
        processor=process,
        max_messages=int(
            os.environ.get(
                "MAX_CONCURRENT_MESSAGES",
                "10",
            )
        ),
    ).run()


if __name__ == "__main__":
    main()