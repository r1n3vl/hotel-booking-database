import sys
from pathlib import Path
from sqlfluff.core import FluffConfig, Linter

ROOT = Path(__file__).resolve().parents[1]


def main():
    config = FluffConfig(overrides={'dialect': 'tsql', 'large_file_skip_byte_limit': 0})
    linter = Linter(config=config)
    failures = 0
    paths = sorted((ROOT / 'sql').glob('*.sql')) + sorted((ROOT / 'examples').glob('*.sql'))
    for path in paths:
        result = linter.parse_string(path.read_text(encoding='utf-8'), fname=str(path))
        if result.violations or result.tree is None:
            failures += 1
            print(f'FAIL {path.relative_to(ROOT)}')
            for violation in result.violations:
                print(f'  {violation}')
        else:
            print(f'PASS {path.relative_to(ROOT)}')
    print(f'{len(paths)-failures}/{len(paths)} SQL files parsed. This does not execute SQL Server.')
    return int(failures > 0)


if __name__ == '__main__':
    sys.exit(main())
