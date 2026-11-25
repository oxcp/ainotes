"""Format the shared session, warm-pool and claim timing summary."""


def timing_table(count: int, submission: float, total: float, *, between_batches: float | None = None,
                 service_setup: float | None = None, route_setup: float | None = None) -> str:
    if count < 1:
        raise ValueError("Timing summary requires a positive Sandbox count.")
    wait = "-" if between_batches is None else f"{between_batches:.3f}s"
    rows = [
        ["Phase", "All Sandboxes", "Average / Sandbox", "Between batches"],
        ["Submission", f"{submission:.3f}s", f"{submission / count:.3f}s",
         "-" if between_batches is None else "0.000s"],
        ["Readiness", f"{total - submission:.3f}s", f"{(total - submission) / count:.3f}s", wait],
        ["Total", f"{total:.3f}s", f"{total / count:.3f}s", wait],
    ]
    for phase, elapsed in (("Services", service_setup), ("HTTPRoutes", route_setup)):
        if elapsed is not None:
            rows.append([phase, f"{elapsed:.3f}s", f"{elapsed / count:.3f}s", "-"])
    widths = [max(len(row[index]) for row in rows) for index in range(4)]

    def line(row: list[str]) -> str:
        return "| " + " | ".join(value.ljust(width) for value, width in zip(row, widths)) + " |"

    separator = "+-" + "-+-".join("-" * width for width in widths) + "-+"
    return "\n".join([separator, line(rows[0]), separator, *(line(row) for row in rows[1:]), separator])
