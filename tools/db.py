import os
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SCHEMA_FILES = [ROOT / 'sql' / name for name in (
    '001_schema.sql', '002_procedures.sql', '003_reporting.sql', '004_security.sql'
)]


def load_env(path=None):
    path = Path(path) if path else ROOT / '.env'
    if not path.exists():
        return
    for line in path.read_text(encoding='utf-8-sig').splitlines():
        line = line.strip()
        if not line or line.startswith('#'):
            continue
        if '=' not in line:
            raise ValueError('Each .env entry must use KEY=VALUE.')
        key, value = line.split('=', 1)
        key, value = key.strip(), value.strip()
        if not re.fullmatch(r'[A-Za-z_][A-Za-z0-9_]*', key):
            raise ValueError('Invalid environment variable name.')
        if len(value) >= 2 and value[0] == value[-1] and value[0] in ('"', "'"):
            value = value[1:-1]
        os.environ.setdefault(key, value)


def quote_identifier(name):
    if not re.fullmatch(r'[A-Za-z][A-Za-z0-9_]{0,59}', name):
        raise ValueError('Database names must use 1-60 ASCII letters, digits or underscores and start with a letter.')
    return '[' + name + ']'


def split_batches(sql):
    batches = []
    current = []
    for line in sql.splitlines():
        stripped = line.strip()
        if re.fullmatch(r'GO(?:\s+--.*)?', stripped, flags=re.IGNORECASE):
            batch = '\n'.join(current).strip()
            if batch:
                batches.append(batch)
            current = []
        elif re.match(r'^GO\s+\d', stripped, flags=re.IGNORECASE):
            raise ValueError('GO repetition counts are not supported.')
        elif stripped.startswith(':'):
            raise ValueError('SQLCMD directives are not supported.')
        else:
            current.append(line)
    batch = '\n'.join(current).strip()
    if batch:
        batches.append(batch)
    return batches


def connect(database='master'):
    import pymssql
    load_env()
    password = os.environ.get('SQLSERVER_PASSWORD') or os.environ.get('MSSQL_SA_PASSWORD')
    if not password:
        raise RuntimeError('Set SQLSERVER_PASSWORD or copy .env.example to .env and set MSSQL_SA_PASSWORD.')
    return pymssql.connect(
        server=os.environ.get('SQLSERVER_HOST', 'localhost'),
        port=os.environ.get('SQLSERVER_PORT', '14333'),
        user=os.environ.get('SQLSERVER_USER', 'sa'),
        password=password,
        database=database,
        charset='UTF-8',
        autocommit=True,
        login_timeout=10,
        timeout=45,
        appname='HotelBookingPortfolio'
    )


def execute_file(connection, path):
    for index, batch in enumerate(split_batches(Path(path).read_text(encoding='utf-8-sig')), start=1):
        with connection.cursor() as cursor:
            try:
                cursor.execute(batch)
                while cursor.nextset():
                    pass
            except Exception as exc:
                raise RuntimeError(f'{Path(path).name}, batch {index}: {exc}') from exc


def create_database(name, seed=False):
    quoted = quote_identifier(name)
    with connect() as connection:
        with connection.cursor() as cursor:
            cursor.execute('SELECT DB_ID(%s)', (name,))
            if cursor.fetchone()[0] is not None:
                raise RuntimeError(f'Database {name} already exists. Choose a new name; init never overwrites databases.')
            cursor.execute(f'CREATE DATABASE {quoted}')
            cursor.execute(f'ALTER DATABASE {quoted} SET COMPATIBILITY_LEVEL = 160')
    try:
        with connect(name) as connection:
            for path in SCHEMA_FILES:
                execute_file(connection, path)
            if seed:
                execute_file(connection, ROOT / 'sql/005_seed.sql')
    except Exception:
        print(f'Initialization failed. Database {name} was retained for inspection.')
        raise


def drop_test_database(name):
    if not re.fullmatch(r'HotelBookingTest_[0-9a-f]{12}', name):
        raise ValueError('Only isolated HotelBookingTest_<12 hex digits> databases may be deleted by this helper.')
    quoted = quote_identifier(name)
    with connect() as connection:
        with connection.cursor() as cursor:
            cursor.execute('SELECT DB_ID(%s)', (name,))
            if cursor.fetchone()[0] is not None:
                cursor.execute(f'ALTER DATABASE {quoted} SET SINGLE_USER WITH ROLLBACK IMMEDIATE')
                cursor.execute(f'DROP DATABASE {quoted}')
