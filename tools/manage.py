import argparse
import os
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from tools.db import ROOT, connect, create_database, execute_file, load_env, quote_identifier


def main():
    load_env()
    parser = argparse.ArgumentParser(description='Install or inspect the Hotel Booking SQL Server project.')
    parser.add_argument('command', choices=['init', 'seed', 'status', 'report'])
    parser.add_argument('--database', default=os.environ.get('SQLSERVER_DATABASE', 'HotelBooking'))
    parser.add_argument('--seed', action='store_true', help='Load synthetic data during init.')
    args = parser.parse_args()
    quote_identifier(args.database)
    if args.seed and args.command != 'init':
        parser.error('--seed is only valid with init')
    if args.command == 'init':
        create_database(args.database, seed=args.seed)
        print(f'Created {args.database}' + (' with demo data.' if args.seed else '.'))
        return
    with connect(args.database) as connection:
        if args.command == 'seed':
            execute_file(connection, ROOT / 'sql/005_seed.sql')
            print('Demo data loaded.')
        elif args.command == 'status':
            with connection.cursor() as cursor:
                cursor.execute('SELECT @@VERSION')
                print(cursor.fetchone()[0])
                cursor.execute('SELECT VersionNumber, AppliedAt, Description FROM hotel.SchemaVersion')
                for row in cursor:
                    print(row)
                for table in ['Hotel', 'Room', 'Guest', 'Booking', 'Payment', 'BookingService']:
                    cursor.execute(f'SELECT COUNT_BIG(*) FROM hotel.{table}')
                    print(f'{table}: {cursor.fetchone()[0]}')
        else:
            with connection.cursor(as_dict=True) as cursor:
                cursor.execute("""
                    SELECT HotelID, SUM(BookedRooms) AS BookedRoomNights,
                        SUM(BookedRoomRevenue) AS BookedRoomRevenue
                    FROM report.vDailyHotelPerformance
                    WHERE StayDate >= '20260101' AND StayDate < '20270101'
                    GROUP BY HotelID ORDER BY HotelID
                """)
                for row in cursor:
                    print(row)


if __name__ == '__main__':
    try:
        main()
    except Exception as exc:
        print(f'ERROR: {exc}', file=sys.stderr)
        sys.exit(1)
