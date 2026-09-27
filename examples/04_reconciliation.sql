SELECT 'Overlapping bookings' AS CheckName, COUNT_BIG(*) AS Violations
FROM hotel.Booking AS a JOIN hotel.Booking AS b ON a.RoomID=b.RoomID AND a.BookingID<b.BookingID
    AND a.CheckInDate<b.CheckOutDate AND a.CheckOutDate>b.CheckInDate
WHERE a.Status<>'CANCELLED' AND b.Status<>'CANCELLED';
SELECT 'Bookings during maintenance' AS CheckName, COUNT_BIG(*) AS Violations
FROM hotel.Booking AS b JOIN hotel.RoomMaintenance AS m ON b.RoomID=m.RoomID
    AND b.CheckInDate<m.EndDate AND b.CheckOutDate>m.StartDate
WHERE b.Status<>'CANCELLED' AND m.IsCancelled=0;
SELECT 'Unsettled completed stays' AS CheckName, COUNT_BIG(*) AS Violations
FROM report.vBookingFinancials WHERE Status='CHECKED_OUT' AND BalanceDue<>0;
SELECT 'Room revenue reconciliation' AS CheckName,
    (SELECT SUM(RoomAmount) FROM report.vBookingFinancials)
    - (SELECT SUM(BookedRoomRevenue) FROM report.vRoomNightLedger) AS Difference;
SELECT 'Payment reconciliation' AS CheckName,
    (SELECT SUM(NetPaid) FROM report.vBookingFinancials)
    - (SELECT SUM(SignedAmount) FROM report.vPaymentLedger) AS Difference;
