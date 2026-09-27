# Setup and operation

## Docker route

Follow the README. `compose.yaml` uses the official `mcr.microsoft.com/mssql/server:2022-latest` image. This moving tag receives SQL Server 2022 updates; to reproduce a specific environment, set `MSSQL_IMAGE` in `.env` to an approved immutable digest from your environment. The workflow intentionally exercises the current 2022 image rather than claiming a pinned binary build.

The container exposes port 14333 on the host loopback interface only. Data is stored in a named Docker volume. Stop without deleting data:

```bash
docker compose stop
```

Start again with `docker compose up -d --wait`. Removing containers with `docker compose down` retains the volume. `docker compose down -v` deletes this project's local volume and all databases in it; use that only when intentionally discarding the development database. No reset command is built into the Python installer.

Changing the password in `.env` does not change an already initialized database login. Keep the configured password consistent with the existing instance.

## Existing SQL Server: SSMS only

Python and Docker are optional. Install or connect to SQL Server 2022 Developer or Express and use SSMS:

1. Connect using an account allowed to create a database.
2. In Object Explorer, right-click **Databases → New Database**. Create a new database named `HotelBooking`.
3. Set its compatibility level to **SQL Server 2022 (160)** in database properties if needed.
4. Open `sql/001_schema.sql`. Select `HotelBooking` in the database dropdown and execute it.
5. Execute `002_procedures.sql`, `003_reporting.sql`, then `004_security.sql` in the same database.
6. Optionally execute `005_seed.sql` to load the demonstration dataset.
7. Run `examples/04_reconciliation.sql`; every violation count and difference should be zero.

Stop and inspect any error before proceeding to the next file. The seed includes historical booking dates, but status-history timestamps record the actual seeding time. These are baseline installation scripts for a new database, not an in-place migration framework. They never drop existing application tables.

SSMS Windows Authentication works without changes to the SQL files. Examples can also be opened directly in SSMS; `GO` is a batch separator recognized by SSMS.

## Existing SQL Server: Python route

Create `.env` with connection settings:

```dotenv
SQLSERVER_HOST=localhost
SQLSERVER_PORT=1433
SQLSERVER_USER=your_development_login
SQLSERVER_PASSWORD='your-local-password'
SQLSERVER_DATABASE=HotelBooking
```

The Python tools use SQL authentication over TCP. They do not implement automatic Windows integrated authentication or SQL Browser discovery. Use a configured TCP port for named instances, or install manually through SSMS.

Shell environment variables take precedence over `.env`; `SQLSERVER_PASSWORD` takes precedence over `MSSQL_SA_PASSWORD`. Do not reuse production credentials. The installer must be able to create a database and install schema objects.

```bash
python tools/manage.py init --seed
python tools/manage.py status
python tools/manage.py report
```

For schema without sample data, omit `--seed`. A later `python tools/manage.py seed` requires an empty application database. Seed reruns fail before modifying data.

If initialization fails partway through, the database is retained for inspection. Correct the cause and initialize a new database name; manually remove only the failed disposable database after inspecting it. There is no automatic rollback of `CREATE DATABASE` and the baseline's separate DDL batches.

## Application roles

`hotel_app` can execute public procedures, read reporting views/functions and read room/service catalogs. It cannot insert, update or delete operational tables directly. `hotel_analyst` can read the reporting schema and cannot change operational tables.

Attach your own database user to a role as an administrator:

```sql
ALTER ROLE hotel_app ADD MEMBER [YourExistingDatabaseUser];
```

This repository does not create application logins or put credentials in source control. Both roles are database-wide; this is not a tenant-isolation design. `report.vGuestSummary` includes names, so grant access accordingly.

API procedures require autocommit calls, with no outer transaction and `IMPLICIT_TRANSACTIONS OFF`. Every mutating operation owns its transaction. If an application receives error 51009 or a transient SQL Server deadlock, retry the entire operation with bounded backoff. Payment retries must retain the original reference and parameters.

## Troubleshooting

| Symptom | Check |
| --- | --- |
| Container is unhealthy | `docker compose logs sqlserver`; password policy, RAM and available disk |
| Connection refused | Container health, the host port in `.env`, TCP enabled on a native instance |
| Login failed after editing `.env` | Existing volume still contains the original login password |
| Existing database error | Use a new database name; `init` intentionally does not overwrite |
| Module not found | Use the same virtual-environment interpreter that installed requirements |
| TLS certificate warning in SSMS | For the local container, enable Trust Server Certificate; configure proper certificates outside local development |
| Apple Silicon / ARM | The supplied SQL Server environment targets x86-64; native ARM execution is not validated |

Developer edition and the loopback/password/TLS choices here are for a development portfolio. Production deployment would need a separate authentication, encryption, backup and operations design.

## References

- [Microsoft: SQL Server container quickstart](https://learn.microsoft.com/en-us/sql/linux/quickstart-install-connect-docker?view=sql-server-ver16)
- [Microsoft: sp_getapplock](https://learn.microsoft.com/en-us/sql/relational-databases/system-stored-procedures/sp-getapplock-transact-sql?view=sql-server-ver16)
- [pymssql documentation](https://pymssql.readthedocs.io/en/stable/)
