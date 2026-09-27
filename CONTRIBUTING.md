# Contributing

Use Python 3.12, SQL Server 2022 and a disposable development database. Install `requirements-dev.txt`, start SQL Server and run:

```bash
python tools/check_sql.py
python -m unittest tests.test_unit tests.test_integration -v
```

Include a failing behavior test when changing a business rule. Preserve half-open dates, decimal money, price snapshots, room-lock ordering and payment-reference replay semantics. Use named arguments in examples and keep database credentials out of commits.

The numbered SQL files are a baseline for new databases. A schema change for an existing installation needs a separately designed migration and backup plan; rerunning the baseline is not an upgrade strategy. Keep API and data-dictionary documentation synchronized with code.
