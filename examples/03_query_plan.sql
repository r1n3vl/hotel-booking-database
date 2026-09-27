SET STATISTICS IO ON;
SET STATISTICS TIME ON;
DECLARE @RoomID int=1, @CheckIn date='20261101', @CheckOut date='20261104';
SELECT BookingID, Status, CheckInDate, CheckOutDate
FROM hotel.Booking
WHERE RoomID=@RoomID AND Status<>'CANCELLED' AND CheckInDate<@CheckOut AND CheckOutDate>@CheckIn;
SET STATISTICS TIME OFF;
SET STATISTICS IO OFF;
