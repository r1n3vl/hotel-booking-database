SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO
CREATE OR ALTER VIEW report.vBookingFinancials
AS
WITH services AS (
    SELECT BookingID, SUM(Amount) AS ServiceAmount FROM hotel.BookingService GROUP BY BookingID
), payments AS (
    SELECT BookingID,
        SUM(CASE WHEN EntryType = 'CAPTURE' THEN Amount ELSE 0 END) AS CapturedAmount,
        SUM(CASE WHEN EntryType = 'REFUND' THEN Amount ELSE 0 END) AS RefundedAmount
    FROM hotel.Payment GROUP BY BookingID
)
SELECT b.BookingID, b.GuestID, r.HotelID, b.RoomID, b.CheckInDate, b.CheckOutDate, b.Status,
    b.RoomAmount AS OriginalRoomAmount,
    CONVERT(decimal(14,2), CASE WHEN b.Status = 'CANCELLED' THEN 0 ELSE b.RoomAmount END) AS RoomAmount,
    CONVERT(decimal(14,2), COALESCE(s.ServiceAmount,0)) AS ServiceAmount,
    CONVERT(decimal(14,2), CASE WHEN b.Status = 'CANCELLED' THEN 0
        ELSE b.RoomAmount + COALESCE(s.ServiceAmount,0) END) AS TotalAmount,
    CONVERT(decimal(14,2), COALESCE(p.CapturedAmount,0)) AS CapturedAmount,
    CONVERT(decimal(14,2), COALESCE(p.RefundedAmount,0)) AS RefundedAmount,
    CONVERT(decimal(14,2), COALESCE(p.CapturedAmount,0) - COALESCE(p.RefundedAmount,0)) AS NetPaid,
    CONVERT(decimal(14,2), CASE WHEN b.Status = 'CANCELLED' THEN 0
        ELSE b.RoomAmount + COALESCE(s.ServiceAmount,0) END
        - COALESCE(p.CapturedAmount,0) + COALESCE(p.RefundedAmount,0)) AS BalanceDue
FROM hotel.Booking AS b JOIN hotel.Room AS r ON r.RoomID = b.RoomID
LEFT JOIN services AS s ON s.BookingID = b.BookingID
LEFT JOIN payments AS p ON p.BookingID = b.BookingID;
GO
CREATE OR ALTER FUNCTION report.fn_AvailableRooms (
    @HotelID int, @CheckInDate date, @CheckOutDate date, @GuestCount int
)
RETURNS TABLE
AS
RETURN (
    SELECT r.RoomID, r.HotelID, r.RoomNumber, t.Name AS RoomType, t.Capacity, r.NightlyRate,
        CONVERT(decimal(14,2), DATEDIFF(day,@CheckInDate,@CheckOutDate) * r.NightlyRate) AS StayAmount
    FROM hotel.Room AS r JOIN hotel.RoomType AS t ON t.RoomTypeID = r.RoomTypeID
    WHERE r.HotelID = @HotelID AND r.IsActive = 1 AND t.Capacity >= @GuestCount AND @GuestCount >= 1
        AND @CheckOutDate > @CheckInDate AND DATEDIFF(day,@CheckInDate,@CheckOutDate) <= 365
        AND @CheckInDate >= '20200101' AND @CheckOutDate <= '20410101'
        AND NOT EXISTS (SELECT 1 FROM hotel.Booking AS b WHERE b.RoomID = r.RoomID
            AND b.Status <> 'CANCELLED' AND b.CheckInDate < @CheckOutDate AND b.CheckOutDate > @CheckInDate)
        AND NOT EXISTS (SELECT 1 FROM hotel.RoomMaintenance AS m WHERE m.RoomID = r.RoomID
            AND m.IsCancelled = 0 AND m.StartDate < @CheckOutDate AND m.EndDate > @CheckInDate)
);
GO
CREATE OR ALTER VIEW report.vRoomNightLedger
AS
SELECT b.BookingID, b.RoomID, r.HotelID, c.CalendarDate AS StayDate, c.MonthStart,
    b.Status, b.NightlyRate AS BookedRoomRevenue
FROM hotel.Booking AS b JOIN hotel.Room AS r ON r.RoomID = b.RoomID
JOIN hotel.CalendarDate AS c ON c.CalendarDate >= b.CheckInDate AND c.CalendarDate < b.CheckOutDate
WHERE b.Status <> 'CANCELLED';
GO
CREATE OR ALTER VIEW report.vDailyHotelPerformance
AS
WITH inventory AS (
    SELECT r.HotelID, c.CalendarDate AS StayDate,
        COUNT_BIG(*) AS TotalRooms,
        SUM(CONVERT(bigint, CASE WHEN m.MaintenanceID IS NULL THEN 1 ELSE 0 END)) AS SellableRooms
    FROM hotel.Room AS r CROSS JOIN hotel.CalendarDate AS c
    LEFT JOIN hotel.RoomMaintenance AS m ON m.RoomID = r.RoomID AND m.IsCancelled = 0
        AND c.CalendarDate >= m.StartDate AND c.CalendarDate < m.EndDate
    WHERE r.IsActive = 1
    GROUP BY r.HotelID, c.CalendarDate
), booked AS (
    SELECT HotelID, StayDate, COUNT_BIG(*) AS BookedRooms, SUM(BookedRoomRevenue) AS BookedRoomRevenue
    FROM report.vRoomNightLedger GROUP BY HotelID, StayDate
)
SELECT h.HotelID, h.Name AS HotelName, c.CalendarDate AS StayDate,
    COALESCE(i.TotalRooms,0) AS TotalRooms, COALESCE(i.SellableRooms,0) AS SellableRooms,
    COALESCE(b.BookedRooms,0) AS BookedRooms,
    CONVERT(decimal(14,2), COALESCE(b.BookedRoomRevenue,0)) AS BookedRoomRevenue,
    CONVERT(decimal(6,2), 100.0 * COALESCE(b.BookedRooms,0) / NULLIF(i.SellableRooms,0)) AS BookedOccupancyPct,
    CONVERT(decimal(14,2), b.BookedRoomRevenue / NULLIF(b.BookedRooms,0)) AS BookedADR,
    CONVERT(decimal(14,2), COALESCE(b.BookedRoomRevenue,0) / NULLIF(i.SellableRooms,0)) AS BookedRevPAR
FROM hotel.Hotel AS h CROSS JOIN hotel.CalendarDate AS c
LEFT JOIN inventory AS i ON i.HotelID = h.HotelID AND i.StayDate = c.CalendarDate
LEFT JOIN booked AS b ON b.HotelID = h.HotelID AND b.StayDate = c.CalendarDate;
GO
CREATE OR ALTER VIEW report.vGuestSummary
AS
SELECT g.GuestID, g.FirstName, g.LastName, COUNT_BIG(b.BookingID) AS BookingCount,
    SUM(CASE WHEN b.Status = 'CHECKED_OUT' THEN 1 ELSE 0 END) AS CompletedStays,
    SUM(CASE WHEN b.Status = 'CANCELLED' THEN 1 ELSE 0 END) AS CancelledStays,
    CONVERT(decimal(14,2), COALESCE(SUM(f.TotalAmount),0)) AS BookedValue,
    CONVERT(decimal(14,2), COALESCE(SUM(f.NetPaid),0)) AS NetPaid
FROM hotel.Guest AS g LEFT JOIN hotel.Booking AS b ON b.GuestID = g.GuestID
LEFT JOIN report.vBookingFinancials AS f ON f.BookingID = b.BookingID
GROUP BY g.GuestID, g.FirstName, g.LastName;
GO
CREATE OR ALTER VIEW report.vPaymentLedger
AS
SELECT p.PaymentID, p.BookingID, r.HotelID, p.EntryType, p.Method, p.Reference, p.RecordedAt,
    CONVERT(decimal(14,2), CASE WHEN p.EntryType = 'CAPTURE' THEN p.Amount ELSE -p.Amount END) AS SignedAmount,
    SUM(CASE WHEN p.EntryType = 'CAPTURE' THEN p.Amount ELSE -p.Amount END)
        OVER (PARTITION BY p.BookingID ORDER BY p.RecordedAt, p.PaymentID ROWS UNBOUNDED PRECEDING) AS RunningNetPaid
FROM hotel.Payment AS p JOIN hotel.Booking AS b ON b.BookingID = p.BookingID
JOIN hotel.Room AS r ON r.RoomID = b.RoomID;
GO
