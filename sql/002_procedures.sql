SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO
CREATE OR ALTER PROCEDURE hotel.usp_LockRoom
    @RoomID int
AS
BEGIN
    SET NOCOUNT ON;
    IF @RoomID IS NULL OR NOT EXISTS (SELECT 1 FROM hotel.Room WHERE RoomID = @RoomID)
        THROW 51002, 'Room does not exist.', 1;
    DECLARE @LockResult int;
    DECLARE @Resource nvarchar(255) = CONCAT(N'hotel:room:', @RoomID);
    EXEC @LockResult = sys.sp_getapplock @Resource = @Resource, @LockMode = 'Exclusive',
        @LockOwner = 'Transaction', @LockTimeout = 10000, @DbPrincipal = 'public';
    IF @LockResult < 0
        THROW 51009, 'Room lock could not be acquired. Retry the complete operation.', 1;
END;
GO
CREATE OR ALTER PROCEDURE api.usp_CreateGuest
    @FirstName nvarchar(60),
    @LastName nvarchar(60),
    @Email nvarchar(254) = NULL,
    @Phone nvarchar(30) = NULL,
    @GuestID int = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    IF @@TRANCOUNT <> 0 OR (@@OPTIONS & 2) = 2
        THROW 51000, 'Call API procedures in autocommit mode without outer or implicit transactions.', 1;
    INSERT hotel.Guest(FirstName, LastName, Email, Phone)
    VALUES (LTRIM(RTRIM(@FirstName)), LTRIM(RTRIM(@LastName)),
        NULLIF(LOWER(LTRIM(RTRIM(@Email))), N''), NULLIF(LTRIM(RTRIM(@Phone)), N''));
    SET @GuestID = CONVERT(int, SCOPE_IDENTITY());
END;
GO

CREATE OR ALTER PROCEDURE api.usp_CreateBooking
    @GuestID int,
    @RoomID int,
    @CheckInDate date,
    @CheckOutDate date,
    @Adults tinyint = 1,
    @Children tinyint = 0,
    @BookingID bigint = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    IF @@TRANCOUNT <> 0 OR (@@OPTIONS & 2) = 2
        THROW 51000, 'Call API procedures in autocommit mode without outer or implicit transactions.', 1;
    SET TRANSACTION ISOLATION LEVEL READ COMMITTED;
    BEGIN TRY
        BEGIN TRANSACTION;

        EXEC hotel.usp_LockRoom @RoomID;
        IF @CheckInDate IS NULL OR @CheckOutDate IS NULL OR @CheckOutDate <= @CheckInDate
            OR DATEDIFF(day, @CheckInDate, @CheckOutDate) > 365
            OR @CheckInDate < '20200101' OR @CheckOutDate > '20410101'
            THROW 51001, 'Invalid stay dates: use 1-365 nights within 2020-2040.', 1;
        IF NOT EXISTS (SELECT 1 FROM hotel.Guest WHERE GuestID = @GuestID)
            THROW 51002, 'Guest does not exist.', 1;
        DECLARE @Rate decimal(12,2), @Capacity tinyint, @Active bit;
        SELECT @Rate = r.NightlyRate, @Capacity = t.Capacity, @Active = r.IsActive
        FROM hotel.Room AS r JOIN hotel.RoomType AS t ON t.RoomTypeID = r.RoomTypeID
        WHERE r.RoomID = @RoomID;
        IF @Active = 0 THROW 51003, 'Room is inactive.', 1;
        IF @Adults IS NULL OR @Children IS NULL OR @Adults < 1 OR @Adults + @Children > @Capacity
            THROW 51004, 'Guest count exceeds room capacity or is invalid.', 1;
        IF EXISTS (SELECT 1 FROM hotel.Booking WHERE RoomID = @RoomID AND Status <> 'CANCELLED'
            AND CheckInDate < @CheckOutDate AND CheckOutDate > @CheckInDate)
            OR EXISTS (SELECT 1 FROM hotel.RoomMaintenance WHERE RoomID = @RoomID AND IsCancelled = 0
            AND StartDate < @CheckOutDate AND EndDate > @CheckInDate)
            THROW 51005, 'Room is unavailable for the requested dates.', 1;
        INSERT hotel.Booking(GuestID, RoomID, CheckInDate, CheckOutDate, Adults, Children, NightlyRate)
        VALUES (@GuestID, @RoomID, @CheckInDate, @CheckOutDate, @Adults, @Children, @Rate);
        SET @BookingID = CONVERT(bigint, SCOPE_IDENTITY());
        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH;
END;
GO

CREATE OR ALTER PROCEDURE api.usp_RescheduleBooking
    @BookingID bigint,
    @CheckInDate date,
    @CheckOutDate date
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    IF @@TRANCOUNT <> 0 OR (@@OPTIONS & 2) = 2
        THROW 51000, 'Call API procedures in autocommit mode without outer or implicit transactions.', 1;
    SET TRANSACTION ISOLATION LEVEL READ COMMITTED;
    BEGIN TRY
        BEGIN TRANSACTION;

        DECLARE @RoomID int, @Status varchar(12), @Rate decimal(12,2), @Paid decimal(14,2);
        SELECT @RoomID = RoomID FROM hotel.Booking WHERE BookingID = @BookingID;
        IF @RoomID IS NULL THROW 51002, 'Booking does not exist.', 1;
        EXEC hotel.usp_LockRoom @RoomID;
        SELECT @Status = Status, @Rate = NightlyRate FROM hotel.Booking WHERE BookingID = @BookingID;
        IF @Status <> 'CONFIRMED' THROW 51006, 'Only confirmed bookings can be rescheduled.', 1;
        IF NOT EXISTS (SELECT 1 FROM hotel.Room WHERE RoomID = @RoomID AND IsActive = 1)
            THROW 51003, 'Room is inactive.', 1;
        IF @CheckInDate IS NULL OR @CheckOutDate IS NULL OR @CheckOutDate <= @CheckInDate
            OR DATEDIFF(day, @CheckInDate, @CheckOutDate) > 365
            OR @CheckInDate < '20200101' OR @CheckOutDate > '20410101'
            THROW 51001, 'Invalid stay dates: use 1-365 nights within 2020-2040.', 1;
        IF EXISTS (SELECT 1 FROM hotel.Booking WHERE RoomID = @RoomID AND BookingID <> @BookingID
            AND Status <> 'CANCELLED' AND CheckInDate < @CheckOutDate AND CheckOutDate > @CheckInDate)
            OR EXISTS (SELECT 1 FROM hotel.RoomMaintenance WHERE RoomID = @RoomID AND IsCancelled = 0
            AND StartDate < @CheckOutDate AND EndDate > @CheckInDate)
            THROW 51005, 'Room is unavailable for the requested dates.', 1;
        SELECT @Paid = COALESCE(SUM(CASE WHEN EntryType = 'CAPTURE' THEN Amount ELSE -Amount END), 0)
        FROM hotel.Payment WHERE BookingID = @BookingID;
        IF @Paid > DATEDIFF(day, @CheckInDate, @CheckOutDate) * @Rate
            THROW 51008, 'Refund the excess payment before shortening the stay.', 1;
        UPDATE hotel.Booking SET CheckInDate = @CheckInDate, CheckOutDate = @CheckOutDate,
            UpdatedAt = SYSUTCDATETIME() WHERE BookingID = @BookingID;
        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH;
END;
GO

CREATE OR ALTER PROCEDURE api.usp_ChangeBookingStatus
    @BookingID bigint,
    @NewStatus varchar(12)
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    IF @@TRANCOUNT <> 0 OR (@@OPTIONS & 2) = 2
        THROW 51000, 'Call API procedures in autocommit mode without outer or implicit transactions.', 1;
    SET TRANSACTION ISOLATION LEVEL READ COMMITTED;
    BEGIN TRY
        BEGIN TRANSACTION;

        DECLARE @RoomID int, @OldStatus varchar(12), @RoomAmount decimal(14,2);
        SELECT @RoomID = RoomID FROM hotel.Booking WHERE BookingID = @BookingID;
        IF @RoomID IS NULL THROW 51002, 'Booking does not exist.', 1;
        EXEC hotel.usp_LockRoom @RoomID;
        SELECT @OldStatus = Status, @RoomAmount = RoomAmount FROM hotel.Booking WHERE BookingID = @BookingID;
        IF @NewStatus IS NULL OR @NewStatus NOT IN ('CONFIRMED','CHECKED_IN','CHECKED_OUT','CANCELLED')
            THROW 51006, 'Unknown booking status.', 1;
        IF @NewStatus <> @OldStatus
        BEGIN
            IF NOT ((@OldStatus = 'CONFIRMED' AND @NewStatus IN ('CHECKED_IN','CANCELLED'))
                OR (@OldStatus = 'CHECKED_IN' AND @NewStatus = 'CHECKED_OUT'))
                THROW 51006, 'Invalid booking status transition.', 1;
            IF @NewStatus = 'CHECKED_OUT'
            BEGIN
                DECLARE @Services decimal(14,2), @Paid decimal(14,2);
                SELECT @Services = COALESCE(SUM(Amount),0) FROM hotel.BookingService WHERE BookingID = @BookingID;
                SELECT @Paid = COALESCE(SUM(CASE WHEN EntryType = 'CAPTURE' THEN Amount ELSE -Amount END),0)
                FROM hotel.Payment WHERE BookingID = @BookingID;
                IF @RoomAmount + @Services <> @Paid
                    THROW 51007, 'Settle the outstanding balance before check-out.', 1;
            END;
            UPDATE hotel.Booking SET Status = @NewStatus, UpdatedAt = SYSUTCDATETIME() WHERE BookingID = @BookingID;
        END;
        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH;
END;
GO

CREATE OR ALTER PROCEDURE api.usp_AddService
    @BookingID bigint,
    @ServiceID int,
    @ServiceDate date,
    @Quantity smallint = 1,
    @BookingServiceID bigint = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    IF @@TRANCOUNT <> 0 OR (@@OPTIONS & 2) = 2
        THROW 51000, 'Call API procedures in autocommit mode without outer or implicit transactions.', 1;
    SET TRANSACTION ISOLATION LEVEL READ COMMITTED;
    BEGIN TRY
        BEGIN TRANSACTION;

        DECLARE @RoomID int, @Status varchar(12), @CheckIn date, @CheckOut date, @Price decimal(12,2);
        SELECT @RoomID = RoomID FROM hotel.Booking WHERE BookingID = @BookingID;
        IF @RoomID IS NULL THROW 51002, 'Booking does not exist.', 1;
        EXEC hotel.usp_LockRoom @RoomID;
        SELECT @Status = Status, @CheckIn = CheckInDate, @CheckOut = CheckOutDate
        FROM hotel.Booking WHERE BookingID = @BookingID;
        IF @Status <> 'CHECKED_IN' THROW 51006, 'Services can only be added to checked-in bookings.', 1;
        IF @ServiceDate IS NULL OR @ServiceDate < @CheckIn OR @ServiceDate >= @CheckOut
            THROW 51001, 'Service date must be a booked night.', 1;
        IF @Quantity IS NULL OR @Quantity NOT BETWEEN 1 AND 1000
            THROW 51001, 'Service quantity must be between 1 and 1000.', 1;
        SELECT @Price = UnitPrice FROM hotel.Service WHERE ServiceID = @ServiceID AND IsActive = 1;
        IF @Price IS NULL THROW 51002, 'Active service does not exist.', 1;
        INSERT hotel.BookingService(BookingID, ServiceID, ServiceDate, Quantity, UnitPrice)
        VALUES (@BookingID, @ServiceID, @ServiceDate, @Quantity, @Price);
        SET @BookingServiceID = CONVERT(bigint, SCOPE_IDENTITY());
        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH;
END;
GO

CREATE OR ALTER PROCEDURE api.usp_RecordPayment
    @BookingID bigint,
    @EntryType varchar(7),
    @Amount decimal(14,2),
    @Method varchar(10),
    @Reference nvarchar(100),
    @PaymentID bigint = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    IF @@TRANCOUNT <> 0 OR (@@OPTIONS & 2) = 2
        THROW 51000, 'Call API procedures in autocommit mode without outer or implicit transactions.', 1;
    SET TRANSACTION ISOLATION LEVEL READ COMMITTED;
    BEGIN TRY
        BEGIN TRANSACTION;

        DECLARE @RoomID int, @Status varchar(12), @RoomAmount decimal(14,2),
            @Services decimal(14,2), @Paid decimal(14,2), @ExistingID bigint;
        SELECT @RoomID = RoomID FROM hotel.Booking WHERE BookingID = @BookingID;
        IF @RoomID IS NULL THROW 51002, 'Booking does not exist.', 1;
        EXEC hotel.usp_LockRoom @RoomID;
        SET @Reference = LTRIM(RTRIM(@Reference));
        IF @Reference IS NULL OR LEN(@Reference) = 0 OR @Amount IS NULL OR @Amount <= 0
            OR @Amount > 100000000 OR @EntryType IS NULL OR @EntryType NOT IN ('CAPTURE','REFUND')
            OR @Method IS NULL OR @Method NOT IN ('CARD','CASH','TRANSFER')
            THROW 51001, 'Invalid payment parameters.', 1;
        DECLARE @RefLock int, @RefResource nvarchar(255) = N'hotel:payment-references';
        EXEC @RefLock = sys.sp_getapplock @Resource = @RefResource, @LockMode = 'Exclusive',
            @LockOwner = 'Transaction', @LockTimeout = 10000, @DbPrincipal = 'public';
        IF @RefLock < 0 THROW 51009, 'Payment reference lock unavailable. Retry the complete operation.', 1;
        SELECT @ExistingID = PaymentID FROM hotel.Payment WHERE Reference = @Reference;
        IF @ExistingID IS NOT NULL
        BEGIN
            IF NOT EXISTS (SELECT 1 FROM hotel.Payment WHERE PaymentID = @ExistingID
                AND BookingID = @BookingID AND EntryType = @EntryType AND Amount = @Amount AND Method = @Method)
                THROW 51010, 'Payment reference already exists with different parameters.', 1;
            SET @PaymentID = @ExistingID;
        END
        ELSE
        BEGIN
            SELECT @Status = Status, @RoomAmount = RoomAmount FROM hotel.Booking WHERE BookingID = @BookingID;
            SELECT @Services = COALESCE(SUM(Amount),0) FROM hotel.BookingService WHERE BookingID = @BookingID;
            SELECT @Paid = COALESCE(SUM(CASE WHEN EntryType = 'CAPTURE' THEN Amount ELSE -Amount END),0)
            FROM hotel.Payment WHERE BookingID = @BookingID;
            IF @EntryType = 'CAPTURE' AND (@Status = 'CANCELLED' OR @Paid + @Amount > @RoomAmount + @Services)
                THROW 51008, 'Payment exceeds the balance or the booking is cancelled.', 1;
            IF @EntryType = 'REFUND' AND (@Amount > @Paid OR @Status = 'CHECKED_OUT')
                THROW 51008, 'Refund exceeds net payments or booking is already settled.', 1;
            INSERT hotel.Payment(BookingID, EntryType, Amount, Method, Reference)
            VALUES (@BookingID, @EntryType, @Amount, @Method, @Reference);
            SET @PaymentID = CONVERT(bigint, SCOPE_IDENTITY());
        END;
        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH;
END;
GO

CREATE OR ALTER PROCEDURE api.usp_AddMaintenance
    @RoomID int,
    @StartDate date,
    @EndDate date,
    @Reason nvarchar(200),
    @MaintenanceID bigint = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    IF @@TRANCOUNT <> 0 OR (@@OPTIONS & 2) = 2
        THROW 51000, 'Call API procedures in autocommit mode without outer or implicit transactions.', 1;
    SET TRANSACTION ISOLATION LEVEL READ COMMITTED;
    BEGIN TRY
        BEGIN TRANSACTION;

        EXEC hotel.usp_LockRoom @RoomID;
        IF @StartDate IS NULL OR @EndDate IS NULL OR @EndDate <= @StartDate
            OR @StartDate < '20200101' OR @EndDate > '20410101'
            OR @Reason IS NULL OR LEN(LTRIM(RTRIM(@Reason))) = 0
            THROW 51001, 'Invalid maintenance dates or reason.', 1;
        IF EXISTS (SELECT 1 FROM hotel.Booking WHERE RoomID = @RoomID AND Status <> 'CANCELLED'
            AND CheckInDate < @EndDate AND CheckOutDate > @StartDate)
            OR EXISTS (SELECT 1 FROM hotel.RoomMaintenance WHERE RoomID = @RoomID AND IsCancelled = 0
            AND StartDate < @EndDate AND EndDate > @StartDate)
            THROW 51005, 'Maintenance overlaps a booking or another maintenance window.', 1;
        INSERT hotel.RoomMaintenance(RoomID, StartDate, EndDate, Reason)
        VALUES (@RoomID, @StartDate, @EndDate, LTRIM(RTRIM(@Reason)));
        SET @MaintenanceID = CONVERT(bigint, SCOPE_IDENTITY());
        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH;
END;
GO

CREATE OR ALTER PROCEDURE api.usp_CancelMaintenance
    @MaintenanceID bigint
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    IF @@TRANCOUNT <> 0 OR (@@OPTIONS & 2) = 2
        THROW 51000, 'Call API procedures in autocommit mode without outer or implicit transactions.', 1;
    SET TRANSACTION ISOLATION LEVEL READ COMMITTED;
    BEGIN TRY
        BEGIN TRANSACTION;

        DECLARE @RoomID int;
        SELECT @RoomID = RoomID FROM hotel.RoomMaintenance WHERE MaintenanceID = @MaintenanceID;
        IF @RoomID IS NULL THROW 51002, 'Maintenance window does not exist.', 1;
        EXEC hotel.usp_LockRoom @RoomID;
        UPDATE hotel.RoomMaintenance SET IsCancelled = 1 WHERE MaintenanceID = @MaintenanceID;
        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH;
END;
GO
