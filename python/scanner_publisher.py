from __future__ import annotations

import glob
import json
import os
import sys
import time
from pathlib import Path
from typing import Any, Iterator

import requests

SOURCE = os.environ["SOURCE"]

AGGREGATOR_URL = os.environ.get(
    "AGGREGATOR_URL",
    (
        "http://event-aggregator."
        "shared-services.svc.cluster.local:8080"
    ),
).rstrip("/")

INPUT_GLOB = os.environ["INPUT_GLOB"]

DONE_FILE = Path(
    os.environ.get(
        "DONE_FILE",
        "/reports/.done",
    )
)

WAIT_TIMEOUT_SECONDS = int(
    os.environ.get(
        "WAIT_TIMEOUT_SECONDS",
        "3600",
    )
)

HTTP_TIMEOUT_SECONDS = int(
    os.environ.get(
        "HTTP_TIMEOUT_SECONDS",
        "60",
    )
)

MAX_RETRIES = int(
    os.environ.get(
        "MAX_RETRIES",
        "5",
    )
)

BATCH_SIZE = int(
    os.environ.get(
        "BATCH_SIZE",
        "100",
    )
)


def log(
    event: str,
    **fields: Any,
) -> None:
    print(
        json.dumps(
            {
                "component": (
                    "scanner-publisher"
                ),
                "event": event,
                "source": SOURCE,
                **fields,
            },
            sort_keys=True,
            default=str,
        ),
        flush=True,
    )


def wait_for_scan() -> None:
    deadline = (
        time.monotonic()
        + WAIT_TIMEOUT_SECONDS
    )

    while (
        time.monotonic()
        < deadline
    ):
        if DONE_FILE.exists():
            return

        time.sleep(2)

    raise TimeoutError(
        f"timed out waiting for {DONE_FILE}"
    )


def load_documents() -> list[Any]:
    paths = [
        Path(path)
        for path in sorted(
            glob.glob(
                INPUT_GLOB,
                recursive=True,
            )
        )
    ]

    if not paths:
        raise FileNotFoundError(
            (
                "no reports matched "
                f"{INPUT_GLOB}"
            )
        )

    documents: list[Any] = []

    for path in paths:
        with path.open(
            "r",
            encoding="utf-8",
        ) as handle:
            documents.append(
                json.load(handle)
            )

    return documents


def payloads(
    documents: list[Any],
) -> Iterator[Any]:
    """
    Send Trivy reports individually and split
    large Prowler arrays into manageable batches.
    """

    for document in documents:
        if (
            SOURCE == "prowler"
            and isinstance(
                document,
                list,
            )
        ):
            for index in range(
                0,
                len(document),
                BATCH_SIZE,
            ):
                yield document[
                    index : index
                    + BATCH_SIZE
                ]

        else:
            yield document


def publish(
    payload: Any,
    batch_number: int,
) -> None:
    url = (
        f"{AGGREGATOR_URL}"
        f"/ingest/{SOURCE}"
    )

    error: Exception | None = None

    for attempt in range(
        1,
        MAX_RETRIES + 1,
    ):
        try:
            response = requests.post(
                url,
                json=payload,
                timeout=(
                    HTTP_TIMEOUT_SECONDS
                ),
            )

            response.raise_for_status()

            log(
                "report_published",
                batch_number=(
                    batch_number
                ),
                attempt=attempt,
                response=response.json(),
            )

            return

        except (
            requests.RequestException,
            ValueError,
        ) as exc:
            error = exc

            log(
                "publish_retry",
                batch_number=(
                    batch_number
                ),
                attempt=attempt,
                error=str(exc),
            )

            time.sleep(
                min(
                    2**attempt,
                    30,
                )
            )

    raise RuntimeError(
        (
            "failed to publish "
            "scan report batch: "
            f"{error}"
        )
    )


def main() -> int:
    try:
        wait_for_scan()

        documents = load_documents()

        batch_count = 0

        for (
            batch_count,
            payload,
        ) in enumerate(
            payloads(documents),
            start=1,
        ):
            publish(
                payload,
                batch_count,
            )

        log(
            "all_reports_published",
            batch_count=batch_count,
        )

        return 0

    except Exception as exc:
        log(
            "publisher_failed",
            error=str(exc),
        )

        return 1


if __name__ == "__main__":
    sys.exit(main())