# Validation status

Prepared on 28 September 2026.

## Checks completed in the authoring environment

| Check | Result |
| --- | --- |
| SQLFluff 3.5.0, T-SQL dialect | All 9 SQL/example files parsed successfully |
| Python runner unit tests | 10 passed |
| Python compilation | All tool and test modules compiled |
| YAML parsing | Docker Compose and GitHub Actions workflow parsed |
| Repository review | Relative documentation links and packaged file inventory checked |

## Checks requiring SQL Server

The project includes **38 integration tests** for actual SQL Server execution:

- Installation of the schema, procedures, reporting objects and permissions.
- Adjacent stays and every overlap shape; invalid dates, capacity and inactive rooms.
- Status transitions, settlement requirements and set-based audit history.
- Price snapshots, multiple services/payments and aggregation without duplicated totals.
- Payment idempotency, conflicting references, overpayments, refunds and cancellation credits.
- Service eligibility and date boundaries; rescheduling and maintenance conflicts.
- Month-boundary room-night allocation, availability and zero-inventory metrics.
- Application-role execution and rejection of direct table writes.
- Two-connection booking, payment and maintenance races.
- Synthetic data counts, non-overlap, financial reconciliation and the documented examples.

**These integration tests were not successfully executed in the authoring environment.** A temporary native SQL Server 2022 engine (package 16.0.4295.3) was downloaded, but it terminated during startup before accepting connections. This is an environment limitation of the delivered validation, not a passing SQL Server result. No database benchmark, Docker startup success or successful GitHub Actions run is claimed.

Run the suite on your local SQL Server or let the included workflow run after pushing to GitHub:

```bash
python tools/check_sql.py
python -m unittest tests.test_unit -v
python -m unittest tests.test_integration -v
```

The integration suite creates isolated test databases and requires create/drop privileges on the development server. Each test database has a random `HotelBookingTest_<12 hex digits>` name. The cleanup helper rejects application database names. If a process is forcibly terminated, an isolated test database may remain and can be inspected before manual cleanup.

The workflow also performs a separate `init --seed`, status and report smoke test. A green workflow run will provide engine-level evidence for that specific commit and the SQL Server image it used. If a test fails, inspect the actual error instead of weakening the assertion to force a pass.
