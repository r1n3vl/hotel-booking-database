DECLARE @FromDate date='20260101', @ToDate date='20270101';
SELECT * FROM report.fn_AvailableRooms(1,'20261010','20261013',2) ORDER BY StayAmount, RoomNumber;
SELECT * FROM report.vDailyHotelPerformance
WHERE HotelID=1 AND StayDate >= '20261001' AND StayDate < '20261101' ORDER BY StayDate;
SELECT d.HotelID, DATEFROMPARTS(YEAR(d.StayDate),MONTH(d.StayDate),1) AS MonthStart,
    SUM(d.BookedRoomRevenue) AS BookedRoomRevenue,
    SUM(d.BookedRooms) AS BookedRoomNights, SUM(d.SellableRooms) AS SellableRoomNights,
    CAST(100.0*SUM(d.BookedRooms)/NULLIF(SUM(d.SellableRooms),0) AS decimal(6,2)) AS BookedOccupancyPct,
    CAST(SUM(d.BookedRoomRevenue)/NULLIF(SUM(d.BookedRooms),0) AS decimal(14,2)) AS BookedADR,
    CAST(SUM(d.BookedRoomRevenue)/NULLIF(SUM(d.SellableRooms),0) AS decimal(14,2)) AS BookedRevPAR
FROM report.vDailyHotelPerformance AS d WHERE d.StayDate>=@FromDate AND d.StayDate<@ToDate
GROUP BY d.HotelID, DATEFROMPARTS(YEAR(d.StayDate),MONTH(d.StayDate),1) ORDER BY MonthStart,d.HotelID;
SELECT TOP (10) GuestID, FirstName, LastName, CompletedStays, NetPaid,
    DENSE_RANK() OVER (ORDER BY NetPaid DESC) AS PaymentRank
FROM report.vGuestSummary WHERE CompletedStays>=2 ORDER BY PaymentRank,GuestID;
SELECT HotelID, DATEFROMPARTS(YEAR(RecordedAt),MONTH(RecordedAt),1) AS CashMonth,
    SUM(SignedAmount) AS NetCashCollected
FROM report.vPaymentLedger WHERE RecordedAt>=@FromDate AND RecordedAt<@ToDate
GROUP BY HotelID,DATEFROMPARTS(YEAR(RecordedAt),MONTH(RecordedAt),1) ORDER BY CashMonth,HotelID;
SELECT BookingID, HotelID, Status, TotalAmount, NetPaid, BalanceDue
FROM report.vBookingFinancials WHERE BalanceDue<>0 ORDER BY BalanceDue DESC,BookingID;
SELECT DATEFROMPARTS(YEAR(CheckInDate),MONTH(CheckInDate),1) AS ArrivalMonth,
    COUNT_BIG(*) AS Bookings,
    SUM(CASE WHEN Status='CANCELLED' THEN 1 ELSE 0 END) AS CancelledBookings,
    CAST(100.0*SUM(CASE WHEN Status='CANCELLED' THEN 1 ELSE 0 END)/COUNT_BIG(*) AS decimal(6,2)) AS CancellationPct
FROM hotel.Booking WHERE CheckInDate>=@FromDate AND CheckInDate<@ToDate
GROUP BY DATEFROMPARTS(YEAR(CheckInDate),MONTH(CheckInDate),1) ORDER BY ArrivalMonth;
SELECT * FROM report.vPaymentLedger WHERE BookingID=11 ORDER BY RecordedAt,PaymentID;
