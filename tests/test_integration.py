import threading
import unittest
import uuid
from concurrent.futures import ThreadPoolExecutor
from decimal import Decimal

import pymssql
from tools.db import ROOT, connect, create_database, drop_test_database, execute_file


class DatabaseFixture(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.database = 'HotelBookingTest_' + uuid.uuid4().hex[:12]
        create_database(cls.database)
        cls.addClassCleanup(drop_test_database, cls.database)

    def setUp(self):
        self.connection = connect(self.database)
        self.addCleanup(self.connection.close)

    def rows(self, sql, params=(), connection=None):
        with (connection or self.connection).cursor() as cursor:
            cursor.execute(sql, params)
            while cursor.description is None:
                if not cursor.nextset():
                    return []
            return cursor.fetchall()

    def scalar(self, sql, params=(), connection=None):
        return self.rows(sql, params, connection)[0][0]

    def assert_sql_error(self, code, sql, params=()):
        with self.assertRaises(pymssql.Error) as result:
            self.rows(sql, params)
        self.assertEqual(result.exception.args[0], code, str(result.exception))
        self.assertEqual(self.scalar('SELECT @@TRANCOUNT'), 0)


class BookingTests(DatabaseFixture):
    def setUp(self):
        super().setUp()
        token = uuid.uuid4().hex[:12]
        self.hotel = self.scalar("INSERT hotel.Hotel(Code,Name,City,Address) VALUES (%s,N'Test',N'Test',N'Test'); SELECT SCOPE_IDENTITY();", (token,))
        self.room_type = self.scalar('INSERT hotel.RoomType(Name,Capacity) VALUES (%s,2); SELECT SCOPE_IDENTITY();', (token,))
        self.room = self.scalar('INSERT hotel.Room(HotelID,RoomTypeID,RoomNumber,FloorNumber,NightlyRate) VALUES (%s,%s,\'101\',1,200); SELECT SCOPE_IDENTITY();', (self.hotel, self.room_type))
        self.guest = self.scalar("DECLARE @id int; EXEC api.usp_CreateGuest N'Test',N'Guest',@GuestID=@id OUTPUT; SELECT @id;")
        self.service = self.scalar('INSERT hotel.Service(Name,UnitPrice) VALUES (%s,25); SELECT SCOPE_IDENTITY();', (token,))

    def booking(self, start='2035-05-10', end='2035-05-13', connection=None):
        return self.scalar('DECLARE @id bigint; EXEC api.usp_CreateBooking %s,%s,%s,%s,@BookingID=@id OUTPUT; SELECT @id;',
                           (self.guest, self.room, start, end), connection)

    def payment(self, booking, amount, entry='CAPTURE', reference=None, connection=None):
        reference = reference or str(uuid.uuid4())
        return self.scalar("DECLARE @id bigint; EXEC api.usp_RecordPayment %s,%s,%s,'CARD',%s,@PaymentID=@id OUTPUT; SELECT @id;",
                           (booking, entry, Decimal(str(amount)), reference), connection)

    def status(self, booking, value):
        self.rows('EXEC api.usp_ChangeBookingStatus %s,%s;', (booking, value))

    def test_create_and_adjacent_checkout_boundary(self):
        first = self.booking()
        second = self.booking('2035-05-13', '2035-05-15')
        self.assertNotEqual(first, second)
        self.assertEqual(self.scalar('SELECT RoomAmount FROM hotel.Booking WHERE BookingID=%s', (first,)), Decimal('600'))

    def test_all_overlap_shapes_rejected_and_rolled_back(self):
        self.booking()
        for start, end in [('2035-05-10','2035-05-13'), ('2035-05-11','2035-05-12'),
                           ('2035-05-09','2035-05-14'), ('2035-05-09','2035-05-11'), ('2035-05-12','2035-05-15')]:
            with self.subTest(start=start, end=end):
                self.assert_sql_error(51005, 'EXEC api.usp_CreateBooking %s,%s,%s,%s;', (self.guest,self.room,start,end))
        self.assertEqual(self.scalar('SELECT COUNT(*) FROM hotel.Booking WHERE RoomID=%s', (self.room,)), 1)

    def test_invalid_dates(self):
        for start, end in [('2035-05-10','2035-05-10'), ('2035-05-13','2035-05-10'),
                           ('2035-01-01','2036-01-02'), (None,'2035-05-13'),
                           ('2019-12-31','2020-01-02'), ('2040-12-31','2041-01-02')]:
            with self.subTest(start=start, end=end):
                self.assert_sql_error(51001, 'EXEC api.usp_CreateBooking %s,%s,%s,%s;', (self.guest,self.room,start,end))

    def test_capacity_counts_children(self):
        self.assert_sql_error(51004, "EXEC api.usp_CreateBooking %s,%s,'20350510','20350513',2,1;", (self.guest,self.room))
        self.assert_sql_error(51004, "EXEC api.usp_CreateBooking %s,%s,'20350510','20350513',0,1;", (self.guest,self.room))

    def test_inactive_room_and_missing_guest(self):
        self.assert_sql_error(51002, "EXEC api.usp_CreateBooking -1,%s,'20350510','20350513';", (self.room,))
        self.rows('UPDATE hotel.Room SET IsActive=0 WHERE RoomID=%s', (self.room,))
        self.assert_sql_error(51003, "EXEC api.usp_CreateBooking %s,%s,'20350510','20350513';", (self.guest,self.room))

    def test_cancelled_booking_frees_inventory(self):
        first = self.booking()
        self.status(first, 'CANCELLED')
        self.assertNotEqual(first, self.booking())

    def test_status_history_and_idempotent_transition(self):
        booking = self.booking()
        self.status(booking,'CHECKED_IN')
        self.status(booking,'CHECKED_IN')
        self.assertEqual(self.rows('SELECT OldStatus,NewStatus FROM hotel.BookingStatusHistory WHERE BookingID=%s ORDER BY HistoryID', (booking,)),
                         [(None,'CONFIRMED'),('CONFIRMED','CHECKED_IN')])

    def test_invalid_status_transitions(self):
        booking = self.booking()
        for status in ['CHECKED_OUT','UNKNOWN',None]:
            self.assert_sql_error(51006,'EXEC api.usp_ChangeBookingStatus %s,%s;', (booking,status))
        self.status(booking,'CANCELLED')
        self.assert_sql_error(51006,"EXEC api.usp_ChangeBookingStatus %s,'CONFIRMED';", (booking,))

    def test_unpaid_checkout_rejected(self):
        booking = self.booking()
        self.status(booking,'CHECKED_IN')
        self.assert_sql_error(51007,"EXEC api.usp_ChangeBookingStatus %s,'CHECKED_OUT';", (booking,))

    def test_full_lifecycle_and_no_join_fanout(self):
        booking = self.booking()
        self.status(booking,'CHECKED_IN')
        self.rows("EXEC api.usp_AddService %s,%s,'20350510',2;", (booking,self.service))
        self.rows("EXEC api.usp_AddService %s,%s,'20350511',1;", (booking,self.service))
        self.payment(booking,100)
        self.payment(booking,575)
        self.status(booking,'CHECKED_OUT')
        self.assertEqual(self.rows('SELECT RoomAmount,ServiceAmount,TotalAmount,NetPaid,BalanceDue FROM report.vBookingFinancials WHERE BookingID=%s', (booking,)),
                         [(Decimal('600'),Decimal('75'),Decimal('675'),Decimal('675'),Decimal('0'))])
        self.assertEqual(self.scalar('SELECT COUNT(*) FROM hotel.BookingStatusHistory WHERE BookingID=%s', (booking,)),3)

    def test_price_snapshots(self):
        booking = self.booking()
        self.rows('UPDATE hotel.Room SET NightlyRate=999 WHERE RoomID=%s', (self.room,))
        self.status(booking,'CHECKED_IN')
        self.rows("EXEC api.usp_AddService %s,%s,'20350510',2;", (booking,self.service))
        self.rows('UPDATE hotel.Service SET UnitPrice=999 WHERE ServiceID=%s', (self.service,))
        self.assertEqual(self.scalar('SELECT TotalAmount FROM report.vBookingFinancials WHERE BookingID=%s', (booking,)),Decimal('650'))

    def test_idempotent_payment_replay_after_cancellation(self):
        booking = self.booking()
        ref = str(uuid.uuid4())
        first = self.payment(booking,100,reference=ref)
        self.status(booking,'CANCELLED')
        second = self.payment(booking,100,reference=ref)
        self.assertEqual(first,second)
        self.assertEqual(self.scalar('SELECT COUNT(*) FROM hotel.Payment WHERE BookingID=%s', (booking,)),1)

    def test_conflicting_payment_reference(self):
        booking = self.booking()
        ref = str(uuid.uuid4())
        self.payment(booking,100,reference=ref)
        self.assert_sql_error(51010,"EXEC api.usp_RecordPayment %s,'CAPTURE',101,'CARD',%s;", (booking,ref))
        other = self.booking('2035-06-10','2035-06-13')
        self.assert_sql_error(51010,"EXEC api.usp_RecordPayment %s,'CAPTURE',100,'CARD',%s;", (other,ref))

    def test_overpayment_and_overrefund(self):
        booking = self.booking()
        self.assert_sql_error(51008,"EXEC api.usp_RecordPayment %s,'CAPTURE',601,'CARD',%s;", (booking,str(uuid.uuid4())))
        self.payment(booking,100)
        self.assert_sql_error(51008,"EXEC api.usp_RecordPayment %s,'REFUND',101,'CARD',%s;", (booking,str(uuid.uuid4())))

    def test_refund_due_after_cancellation(self):
        booking = self.booking()
        self.payment(booking,100)
        self.status(booking,'CANCELLED')
        self.assertEqual(self.scalar('SELECT BalanceDue FROM report.vBookingFinancials WHERE BookingID=%s', (booking,)),Decimal('-100'))
        self.payment(booking,100,entry='REFUND')
        self.assertEqual(self.scalar('SELECT BalanceDue FROM report.vBookingFinancials WHERE BookingID=%s', (booking,)),Decimal('0'))
        self.assert_sql_error(51008,"EXEC api.usp_RecordPayment %s,'CAPTURE',1,'CARD',%s;", (booking,str(uuid.uuid4())))

    def test_settled_booking_cannot_be_refunded(self):
        booking = self.booking()
        self.status(booking,'CHECKED_IN')
        self.payment(booking,600)
        self.status(booking,'CHECKED_OUT')
        self.assert_sql_error(51008,"EXEC api.usp_RecordPayment %s,'REFUND',1,'CARD',%s;", (booking,str(uuid.uuid4())))

    def test_invalid_payment_parameters(self):
        booking = self.booking()
        for entry, amount, method, ref in [('CAPTURE',0,'CARD','a'),('CAPTURE',-1,'CARD','b'),
                                          ('CAPTURE',1,'OTHER','c'),('INVALID',1,'CARD','d'),
                                          ('CAPTURE',1,'CARD',''),('CAPTURE',1,'CARD',None)]:
            with self.subTest(entry=entry,amount=amount,method=method,ref=ref):
                self.assert_sql_error(51001,'EXEC api.usp_RecordPayment %s,%s,%s,%s,%s;', (booking,entry,amount,method,ref))

    def test_services_require_checkin_and_stay_date(self):
        booking = self.booking()
        self.assert_sql_error(51006,"EXEC api.usp_AddService %s,%s,'20350510',1;", (booking,self.service))
        self.status(booking,'CHECKED_IN')
        for date, quantity in [('2035-05-09',1),('2035-05-13',1),('2035-05-10',0)]:
            self.assert_sql_error(51001,'EXEC api.usp_AddService %s,%s,%s,%s;', (booking,self.service,date,quantity))
        self.rows('UPDATE hotel.Service SET IsActive=0 WHERE ServiceID=%s', (self.service,))
        self.assert_sql_error(51002,"EXEC api.usp_AddService %s,%s,'20350510',1;", (booking,self.service))

    def test_reschedule_and_conflict(self):
        booking = self.booking()
        self.booking('2035-06-10','2035-06-13')
        self.assert_sql_error(51005,"EXEC api.usp_RescheduleBooking %s,'20350611','20350614';", (booking,))
        self.rows("EXEC api.usp_RescheduleBooking %s,'20350710','20350714';", (booking,))
        self.assertEqual(self.scalar('SELECT RoomAmount FROM hotel.Booking WHERE BookingID=%s', (booking,)),Decimal('800'))
        self.status(booking,'CHECKED_IN')
        self.assert_sql_error(51006,"EXEC api.usp_RescheduleBooking %s,'20350810','20350814';", (booking,))

    def test_shortening_paid_stay_requires_refund(self):
        booking = self.booking()
        self.payment(booking,600)
        self.assert_sql_error(51008,"EXEC api.usp_RescheduleBooking %s,'20350510','20350512';", (booking,))
        self.payment(booking,200,entry='REFUND')
        self.rows("EXEC api.usp_RescheduleBooking %s,'20350510','20350512';", (booking,))
        self.assertEqual(self.scalar('SELECT BalanceDue FROM report.vBookingFinancials WHERE BookingID=%s', (booking,)),Decimal('0'))

    def test_maintenance_blocks_booking_and_can_be_cancelled(self):
        maintenance = self.scalar("DECLARE @id bigint; EXEC api.usp_AddMaintenance %s,'20350510','20350513',N'Repair',@id OUTPUT; SELECT @id;", (self.room,))
        self.assert_sql_error(51005,"EXEC api.usp_CreateBooking %s,%s,'20350510','20350513';", (self.guest,self.room))
        self.assert_sql_error(51005,"EXEC api.usp_AddMaintenance %s,'20350511','20350512',N'Repair';", (self.room,))
        self.rows('EXEC api.usp_CancelMaintenance %s;', (maintenance,))
        self.booking()

    def test_booking_blocks_maintenance(self):
        self.booking()
        self.assert_sql_error(51005,"EXEC api.usp_AddMaintenance %s,'20350510','20350513',N'Repair';", (self.room,))

    def test_availability_capacity_and_boundaries(self):
        self.booking()
        self.assertEqual(self.scalar("SELECT COUNT(*) FROM report.fn_AvailableRooms(%s,'20350511','20350512',1)", (self.hotel,)),0)
        self.assertEqual(self.scalar("SELECT COUNT(*) FROM report.fn_AvailableRooms(%s,'20350513','20350514',2)", (self.hotel,)),1)
        self.assertEqual(self.scalar("SELECT COUNT(*) FROM report.fn_AvailableRooms(%s,'20350513','20350514',3)", (self.hotel,)),0)
        self.assertEqual(self.scalar("SELECT COUNT(*) FROM report.fn_AvailableRooms(%s,'20350513','20350513',1)", (self.hotel,)),0)

    def test_room_nights_split_at_month_boundary(self):
        booking = self.booking('2035-02-27','2035-03-02')
        self.assertEqual(self.rows('SELECT MONTH(StayDate),SUM(BookedRoomRevenue) FROM report.vRoomNightLedger WHERE BookingID=%s GROUP BY MONTH(StayDate) ORDER BY MONTH(StayDate)', (booking,)),
                         [(2,Decimal('400')),(3,Decimal('200'))])

    def test_zero_inventory_and_maintenance_denominator(self):
        self.rows("EXEC api.usp_AddMaintenance %s,'20350510','20350513',N'Repair';", (self.room,))
        self.assertEqual(self.rows("SELECT TotalRooms,SellableRooms,BookedRooms,BookedOccupancyPct,BookedRevPAR FROM report.vDailyHotelPerformance WHERE HotelID=%s AND StayDate='20350511'", (self.hotel,)),[(1,0,0,None,None)])
        self.rows('UPDATE hotel.Room SET IsActive=0 WHERE RoomID=%s', (self.room,))
        self.assertEqual(self.scalar("SELECT TotalRooms FROM report.vDailyHotelPerformance WHERE HotelID=%s AND StayDate='20350511'", (self.hotel,)),0)

    def test_multirow_audit_trigger(self):
        self.booking()
        self.booking('2035-06-10','2035-06-13')
        self.rows("UPDATE hotel.Booking SET Status='CANCELLED' WHERE RoomID=%s", (self.room,))
        self.assertEqual(self.scalar("SELECT COUNT(*) FROM hotel.BookingStatusHistory h JOIN hotel.Booking b ON b.BookingID=h.BookingID WHERE b.RoomID=%s AND h.OldStatus='CONFIRMED' AND h.NewStatus='CANCELLED'", (self.room,)),2)

    def test_role_can_use_api_but_cannot_write_tables(self):
        self.rows("IF USER_ID('TestApp') IS NULL BEGIN CREATE USER TestApp WITHOUT LOGIN; ALTER ROLE hotel_app ADD MEMBER TestApp; END;")
        self.rows("EXECUTE AS USER='TestApp';")
        try:
            booking = self.booking()
            self.assertEqual(self.scalar('SELECT BalanceDue FROM report.vBookingFinancials WHERE BookingID=%s', (booking,)),Decimal('600'))
            self.assert_sql_error(229,"UPDATE hotel.Booking SET Status='CANCELLED' WHERE BookingID=%s", (booking,))
        finally:
            self.rows('REVERT;')

    def test_missing_entities(self):
        self.assert_sql_error(51002,"EXEC api.usp_ChangeBookingStatus -1,'CANCELLED';")
        self.assert_sql_error(51002,'EXEC api.usp_CancelMaintenance -1;')

    def race(self, first, second):
        barrier = threading.Barrier(2, timeout=10)
        def run(operation):
            with connect(self.database) as connection:
                barrier.wait()
                try:
                    return ('ok', operation(connection))
                except pymssql.Error as exc:
                    return ('error', exc.args[0])
        with ThreadPoolExecutor(max_workers=2) as executor:
            futures = [executor.submit(run, first),executor.submit(run, second)]
            return [future.result(timeout=30) for future in futures]

    def test_concurrent_overlapping_bookings(self):
        result = self.race(lambda c:self.booking(connection=c), lambda c:self.booking(connection=c))
        self.assertEqual(sorted(item[0] for item in result),['error','ok'])
        self.assertEqual([item[1] for item in result if item[0]=='error'],[51005])

    def test_concurrent_idempotent_payment(self):
        booking = self.booking()
        ref = str(uuid.uuid4())
        result = self.race(lambda c:self.payment(booking,100,reference=ref,connection=c),lambda c:self.payment(booking,100,reference=ref,connection=c))
        self.assertEqual(result[0],result[1])
        self.assertEqual(result[0][0],'ok')
        self.assertEqual(self.scalar('SELECT COUNT(*) FROM hotel.Payment WHERE BookingID=%s', (booking,)),1)

    def test_concurrent_payments_cannot_overpay(self):
        booking = self.booking()
        result = self.race(lambda c:self.payment(booking,400,connection=c),lambda c:self.payment(booking,400,connection=c))
        self.assertEqual(sorted(item[0] for item in result),['error','ok'])
        self.assertEqual([item[1] for item in result if item[0]=='error'],[51008])
        self.assertEqual(self.scalar('SELECT NetPaid FROM report.vBookingFinancials WHERE BookingID=%s', (booking,)),Decimal('400'))

    def test_concurrent_maintenance_and_booking(self):
        result = self.race(lambda c:self.booking(connection=c),lambda c:self.rows("EXEC api.usp_AddMaintenance %s,'20350510','20350513',N'Repair';", (self.room,),c))
        self.assertEqual(sorted(item[0] for item in result),['error','ok'])
        self.assertEqual([item[1] for item in result if item[0]=='error'],[51005])


class SeedTests(DatabaseFixture):
    @classmethod
    def setUpClass(cls):
        super().setUpClass()
        with connect(cls.database) as connection:
            execute_file(connection,ROOT/'sql/005_seed.sql')

    def test_seed_counts(self):
        for table, expected in [('Hotel',3),('Room',36),('Guest',120),('Booking',864),('RoomMaintenance',72)]:
            with self.subTest(table=table):
                self.assertEqual(self.scalar(f'SELECT COUNT(*) FROM hotel.{table}'),expected)

    def test_seed_has_no_overlaps(self):
        self.assertEqual(self.scalar("SELECT COUNT(*) FROM hotel.Booking a JOIN hotel.Booking b ON a.RoomID=b.RoomID AND a.BookingID<b.BookingID AND a.CheckInDate<b.CheckOutDate AND a.CheckOutDate>b.CheckInDate WHERE a.Status<>'CANCELLED' AND b.Status<>'CANCELLED'"),0)
        self.assertEqual(self.scalar("SELECT COUNT(*) FROM hotel.Booking b JOIN hotel.RoomMaintenance m ON b.RoomID=m.RoomID AND b.CheckInDate<m.EndDate AND b.CheckOutDate>m.StartDate WHERE b.Status<>'CANCELLED' AND m.IsCancelled=0"),0)

    def test_seed_financials_reconcile(self):
        self.assertEqual(self.scalar('SELECT SUM(RoomAmount) FROM report.vBookingFinancials'),self.scalar('SELECT SUM(BookedRoomRevenue) FROM report.vRoomNightLedger'))
        self.assertEqual(self.scalar('SELECT SUM(NetPaid) FROM report.vBookingFinancials'),self.scalar('SELECT SUM(SignedAmount) FROM report.vPaymentLedger'))
        self.assertEqual(self.scalar("SELECT COUNT(*) FROM report.vBookingFinancials WHERE Status='CHECKED_OUT' AND BalanceDue<>0"),0)
        self.assertEqual(self.scalar('SELECT COUNT(*) FROM report.vBookingFinancials WHERE NetPaid<0'),0)

    def test_second_seed_refused_without_changes(self):
        with self.assertRaisesRegex(RuntimeError,'Seed data requires'):
            execute_file(self.connection,ROOT/'sql/005_seed.sql')
        self.assertEqual(self.scalar('SELECT COUNT(*) FROM hotel.Booking'),864)

    def test_reconciliation_examples_execute(self):
        execute_file(self.connection,ROOT/'examples/04_reconciliation.sql')
        execute_file(self.connection,ROOT/'examples/02_reports.sql')
        execute_file(self.connection,ROOT/'examples/03_query_plan.sql')


class DemoLifecycleTests(DatabaseFixture):
    def test_documented_demo(self):
        execute_file(self.connection,ROOT/'sql/005_seed.sql')
        execute_file(self.connection,ROOT/'examples/01_booking_lifecycle.sql')
        self.assertEqual(self.scalar('SELECT COUNT(*) FROM hotel.Booking'),865)
        self.assertEqual(self.scalar("SELECT COUNT(*) FROM report.vBookingFinancials WHERE Status='CHECKED_OUT' AND BalanceDue<>0"),0)


if __name__ == '__main__':
    unittest.main()
