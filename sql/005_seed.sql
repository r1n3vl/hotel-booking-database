SET NOCOUNT ON;
SET XACT_ABORT ON;
IF EXISTS (SELECT 1 FROM hotel.Hotel) OR EXISTS (SELECT 1 FROM hotel.Guest)
    THROW 51020, 'Seed data requires an empty application database. Nothing was changed.', 1;
BEGIN TRANSACTION;
INSERT hotel.Hotel(Code, Name, City, Address) VALUES
    ('WAW-CENTRAL', N'Vistula Central', N'Warsaw', N'Example Street 10'),
    ('KRK-GARDEN', N'Old Town Garden', N'Krakow', N'Example Street 20'),
    ('GDN-MARINA', N'Baltic Marina', N'Gdansk', N'Example Street 30');
INSERT hotel.RoomType(Name, Capacity) VALUES (N'Single',1),(N'Double',2),(N'Triple',3),(N'Family',4);
WITH numbers AS (
    SELECT n FROM (VALUES(1),(2),(3),(4),(5),(6),(7),(8),(9),(10),(11),(12)) AS v(n)
)
INSERT hotel.Room(HotelID, RoomTypeID, RoomNumber, FloorNumber, NightlyRate)
SELECT h.HotelID, t.RoomTypeID, CONVERT(varchar(10),100+n.n), 1,
    CONVERT(decimal(12,2),180 + t.Capacity*70 + CASE h.Code WHEN 'WAW-CENTRAL' THEN 40 WHEN 'GDN-MARINA' THEN 20 ELSE 0 END)
FROM hotel.Hotel AS h CROSS JOIN numbers AS n JOIN hotel.RoomType AS t ON t.Capacity = 1+(n.n-1)%4
ORDER BY h.HotelID,n.n;
WITH digits AS (SELECT n FROM (VALUES(0),(1),(2),(3),(4),(5),(6),(7),(8),(9)) AS v(n)),
nums AS (SELECT 1+a.n+10*b.n+100*c.n AS n FROM digits AS a CROSS JOIN digits AS b CROSS JOIN digits AS c)
INSERT hotel.Guest(FirstName, LastName, Email)
SELECT CONCAT(N'Demo', n), CONCAT(N'Guest', n), CONCAT(N'guest', n, N'@example.com')
FROM nums WHERE n <= 120 ORDER BY n;
INSERT hotel.Service(Name, UnitPrice) VALUES
    (N'Breakfast',45),(N'Parking',60),(N'Spa visit',150),(N'Airport transfer',120),(N'Laundry',35);
WITH months AS (SELECT n FROM (VALUES(1),(2),(3),(4),(5),(6),(7),(8),(9),(10),(11),(12)) AS v(n)),
slots AS (SELECT n FROM (VALUES(0),(1)) AS v(n)),
guests AS (SELECT GuestID, ROW_NUMBER() OVER (ORDER BY GuestID) AS rn FROM hotel.Guest),
rooms AS (SELECT RoomID, RoomTypeID, NightlyRate, ROW_NUMBER() OVER (ORDER BY RoomID) AS rn FROM hotel.Room)
INSERT hotel.Booking(GuestID, RoomID, CheckInDate, CheckOutDate, Adults, Children, NightlyRate, CreatedAt, UpdatedAt)
SELECT g.GuestID, r.RoomID, DATEFROMPARTS(2026,m.n,3+15*s.n),
    DATEADD(day,2+(r.rn+m.n+s.n)%4,DATEFROMPARTS(2026,m.n,3+15*s.n)),
    CASE WHEN t.Capacity = 1 THEN 1 ELSE 2 END, 0, r.NightlyRate,
    DATEADD(day,-30,CONVERT(datetime2(0),DATEFROMPARTS(2026,m.n,3+15*s.n))),
    CONVERT(datetime2(0),DATEFROMPARTS(2026,m.n,3+15*s.n))
FROM rooms AS r CROSS JOIN months AS m CROSS JOIN slots AS s
JOIN hotel.RoomType AS t ON t.RoomTypeID = r.RoomTypeID
JOIN guests AS g ON g.rn = 1+(r.rn*13+m.n*7+s.n*3)%120
ORDER BY r.rn,m.n,s.n;
UPDATE hotel.Booking SET Status = 'CANCELLED' WHERE BookingID % 11 = 0;
UPDATE hotel.Booking SET Status = 'CHECKED_IN' WHERE Status = 'CONFIRMED' AND CheckInDate < '20260919';
INSERT hotel.BookingService(BookingID, ServiceID, ServiceDate, Quantity, UnitPrice)
SELECT b.BookingID, s.ServiceID, b.CheckInDate, b.Adults, s.UnitPrice
FROM hotel.Booking AS b CROSS JOIN hotel.Service AS s WHERE b.Status = 'CHECKED_IN' AND s.Name = N'Breakfast';
INSERT hotel.BookingService(BookingID, ServiceID, ServiceDate, Quantity, UnitPrice)
SELECT b.BookingID, s.ServiceID, b.CheckInDate, DATEDIFF(day,b.CheckInDate,b.CheckOutDate), s.UnitPrice
FROM hotel.Booking AS b CROSS JOIN hotel.Service AS s
WHERE b.Status = 'CHECKED_IN' AND b.BookingID % 3 = 0 AND s.Name = N'Parking';
INSERT hotel.Payment(BookingID, EntryType, Amount, Method, Reference, RecordedAt)
SELECT f.BookingID, 'CAPTURE',
    CASE WHEN f.Status = 'CANCELLED' THEN ROUND(f.OriginalRoomAmount*0.3,2)
        WHEN f.CheckOutDate < '20260919' THEN f.TotalAmount ELSE ROUND(f.TotalAmount*0.3,2) END,
    CASE WHEN f.BookingID % 2 = 0 THEN 'CARD' ELSE 'TRANSFER' END,
    CONCAT(N'DEMO-CAPTURE-', f.BookingID), DATEADD(day,-7,CONVERT(datetime2(0),f.CheckInDate))
FROM report.vBookingFinancials AS f;
INSERT hotel.Payment(BookingID, EntryType, Amount, Method, Reference, RecordedAt)
SELECT p.BookingID, 'REFUND', p.Amount, p.Method, CONCAT(N'DEMO-REFUND-',p.BookingID), DATEADD(day,1,p.RecordedAt)
FROM hotel.Payment AS p JOIN hotel.Booking AS b ON b.BookingID = p.BookingID WHERE b.Status = 'CANCELLED';
UPDATE hotel.Booking SET Status = 'CHECKED_OUT' WHERE Status = 'CHECKED_IN' AND CheckOutDate < '20260919';
INSERT hotel.RoomMaintenance(RoomID, StartDate, EndDate, Reason)
SELECT r.RoomID, DATEFROMPARTS(2026,m.n,10), DATEFROMPARTS(2026,m.n,12), N'Scheduled maintenance'
FROM hotel.Room AS r CROSS JOIN (VALUES(3),(10)) AS m(n);
COMMIT TRANSACTION;
GO
