DECLARE @GuestID int, @RoomID int, @BookingID bigint, @ServiceID int, @Balance decimal(14,2);
EXEC api.usp_CreateGuest @FirstName=N'Alex', @LastName=N'Demo', @Email=NULL, @GuestID=@GuestID OUTPUT;
SELECT TOP (1) @RoomID=RoomID FROM report.fn_AvailableRooms(1,'20300510','20300513',2) ORDER BY RoomID;
IF @RoomID IS NULL THROW 51030, 'No demo room available. Choose different dates.', 1;
EXEC api.usp_CreateBooking @GuestID=@GuestID, @RoomID=@RoomID,
    @CheckInDate='20300510', @CheckOutDate='20300513', @Adults=2, @BookingID=@BookingID OUTPUT;
EXEC api.usp_ChangeBookingStatus @BookingID, 'CHECKED_IN';
SELECT @ServiceID=ServiceID FROM hotel.Service WHERE Name=N'Breakfast';
EXEC api.usp_AddService @BookingID, @ServiceID, '20300510', 2;
SELECT @Balance=BalanceDue FROM report.vBookingFinancials WHERE BookingID=@BookingID;
DECLARE @Reference nvarchar(100)=CONCAT(N'LIFECYCLE-',@BookingID);
EXEC api.usp_RecordPayment @BookingID, 'CAPTURE', @Balance, 'CARD', @Reference;
EXEC api.usp_ChangeBookingStatus @BookingID, 'CHECKED_OUT';
SELECT * FROM report.vBookingFinancials WHERE BookingID=@BookingID;
SELECT * FROM hotel.BookingStatusHistory WHERE BookingID=@BookingID ORDER BY HistoryID;
