SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
SET XACT_ABORT ON;
GO
CREATE SCHEMA hotel AUTHORIZATION dbo;
GO
CREATE SCHEMA api AUTHORIZATION dbo;
GO
CREATE SCHEMA report AUTHORIZATION dbo;
GO
CREATE TABLE hotel.SchemaVersion (
    VersionNumber int NOT NULL CONSTRAINT PK_SchemaVersion PRIMARY KEY,
    AppliedAt datetime2(0) NOT NULL CONSTRAINT DF_SchemaVersion_AppliedAt DEFAULT SYSUTCDATETIME(),
    Description nvarchar(200) NOT NULL
);
CREATE TABLE hotel.Hotel (
    HotelID int IDENTITY(1,1) NOT NULL CONSTRAINT PK_Hotel PRIMARY KEY,
    Code varchar(20) NOT NULL CONSTRAINT UQ_Hotel_Code UNIQUE,
    Name nvarchar(120) NOT NULL,
    City nvarchar(80) NOT NULL,
    Address nvarchar(200) NOT NULL,
    CONSTRAINT CK_Hotel_Code CHECK (LEN(LTRIM(RTRIM(Code))) > 0)
);
CREATE TABLE hotel.RoomType (
    RoomTypeID int IDENTITY(1,1) NOT NULL CONSTRAINT PK_RoomType PRIMARY KEY,
    Name nvarchar(50) NOT NULL CONSTRAINT UQ_RoomType_Name UNIQUE,
    Capacity tinyint NOT NULL CONSTRAINT CK_RoomType_Capacity CHECK (Capacity BETWEEN 1 AND 8)
);
CREATE TABLE hotel.Room (
    RoomID int IDENTITY(1,1) NOT NULL CONSTRAINT PK_Room PRIMARY KEY,
    HotelID int NOT NULL CONSTRAINT FK_Room_Hotel REFERENCES hotel.Hotel(HotelID),
    RoomTypeID int NOT NULL CONSTRAINT FK_Room_RoomType REFERENCES hotel.RoomType(RoomTypeID),
    RoomNumber varchar(10) NOT NULL,
    FloorNumber smallint NOT NULL,
    NightlyRate decimal(12,2) NOT NULL CONSTRAINT CK_Room_Rate CHECK (NightlyRate > 0 AND NightlyRate <= 100000),
    IsActive bit NOT NULL CONSTRAINT DF_Room_IsActive DEFAULT 1,
    CONSTRAINT UQ_Room_Hotel_Number UNIQUE (HotelID, RoomNumber)
);
CREATE TABLE hotel.Guest (
    GuestID int IDENTITY(1,1) NOT NULL CONSTRAINT PK_Guest PRIMARY KEY,
    FirstName nvarchar(60) NOT NULL,
    LastName nvarchar(60) NOT NULL,
    Email nvarchar(254) NULL,
    Phone nvarchar(30) NULL,
    CreatedAt datetime2(0) NOT NULL CONSTRAINT DF_Guest_CreatedAt DEFAULT SYSUTCDATETIME(),
    CONSTRAINT CK_Guest_Names CHECK (LEN(LTRIM(RTRIM(FirstName))) > 0 AND LEN(LTRIM(RTRIM(LastName))) > 0),
    CONSTRAINT CK_Guest_Email CHECK (Email IS NULL OR (Email = LOWER(LTRIM(RTRIM(Email))) AND Email LIKE N'%_@_%._%'))
);
CREATE UNIQUE INDEX UX_Guest_Email ON hotel.Guest(Email) WHERE Email IS NOT NULL;
CREATE TABLE hotel.Booking (
    BookingID bigint IDENTITY(1,1) NOT NULL CONSTRAINT PK_Booking PRIMARY KEY,
    GuestID int NOT NULL CONSTRAINT FK_Booking_Guest REFERENCES hotel.Guest(GuestID),
    RoomID int NOT NULL CONSTRAINT FK_Booking_Room REFERENCES hotel.Room(RoomID),
    CheckInDate date NOT NULL,
    CheckOutDate date NOT NULL,
    Adults tinyint NOT NULL,
    Children tinyint NOT NULL CONSTRAINT DF_Booking_Children DEFAULT 0,
    NightlyRate decimal(12,2) NOT NULL,
    Status varchar(12) NOT NULL CONSTRAINT DF_Booking_Status DEFAULT 'CONFIRMED',
    CreatedAt datetime2(0) NOT NULL CONSTRAINT DF_Booking_CreatedAt DEFAULT SYSUTCDATETIME(),
    UpdatedAt datetime2(0) NOT NULL CONSTRAINT DF_Booking_UpdatedAt DEFAULT SYSUTCDATETIME(),
    RoomAmount AS CONVERT(decimal(14,2), DATEDIFF(day, CheckInDate, CheckOutDate) * NightlyRate) PERSISTED,
    VersionStamp rowversion NOT NULL,
    CONSTRAINT CK_Booking_Dates CHECK (CheckOutDate > CheckInDate AND DATEDIFF(day, CheckInDate, CheckOutDate) <= 365
        AND CheckInDate >= '20200101' AND CheckOutDate <= '20410101'),
    CONSTRAINT CK_Booking_Occupants CHECK (Adults BETWEEN 1 AND 8 AND Children BETWEEN 0 AND 7 AND Adults + Children <= 8),
    CONSTRAINT CK_Booking_Rate CHECK (NightlyRate > 0 AND NightlyRate <= 100000),
    CONSTRAINT CK_Booking_Status CHECK (Status IN ('CONFIRMED','CHECKED_IN','CHECKED_OUT','CANCELLED'))
);
CREATE INDEX IX_Booking_Room_Dates ON hotel.Booking(RoomID, CheckInDate, CheckOutDate)
    INCLUDE (Status, Adults, Children, NightlyRate, GuestID);
CREATE INDEX IX_Booking_Guest ON hotel.Booking(GuestID, CheckInDate) INCLUDE (Status, RoomID);
CREATE TABLE hotel.BookingStatusHistory (
    HistoryID bigint IDENTITY(1,1) NOT NULL CONSTRAINT PK_BookingStatusHistory PRIMARY KEY,
    BookingID bigint NOT NULL CONSTRAINT FK_History_Booking REFERENCES hotel.Booking(BookingID),
    OldStatus varchar(12) NULL,
    NewStatus varchar(12) NOT NULL,
    ChangedAt datetime2(0) NOT NULL CONSTRAINT DF_History_ChangedAt DEFAULT SYSUTCDATETIME(),
    ChangedBy sysname NOT NULL
);
CREATE INDEX IX_History_Booking ON hotel.BookingStatusHistory(BookingID, HistoryID);
CREATE TABLE hotel.Service (
    ServiceID int IDENTITY(1,1) NOT NULL CONSTRAINT PK_Service PRIMARY KEY,
    Name nvarchar(80) NOT NULL CONSTRAINT UQ_Service_Name UNIQUE,
    UnitPrice decimal(12,2) NOT NULL CONSTRAINT CK_Service_Price CHECK (UnitPrice > 0 AND UnitPrice <= 100000),
    IsActive bit NOT NULL CONSTRAINT DF_Service_IsActive DEFAULT 1
);
CREATE TABLE hotel.BookingService (
    BookingServiceID bigint IDENTITY(1,1) NOT NULL CONSTRAINT PK_BookingService PRIMARY KEY,
    BookingID bigint NOT NULL CONSTRAINT FK_BookingService_Booking REFERENCES hotel.Booking(BookingID),
    ServiceID int NOT NULL CONSTRAINT FK_BookingService_Service REFERENCES hotel.Service(ServiceID),
    ServiceDate date NOT NULL,
    Quantity smallint NOT NULL CONSTRAINT CK_BookingService_Quantity CHECK (Quantity BETWEEN 1 AND 1000),
    UnitPrice decimal(12,2) NOT NULL CONSTRAINT CK_BookingService_Price CHECK (UnitPrice > 0 AND UnitPrice <= 100000),
    Amount AS CONVERT(decimal(14,2), Quantity * UnitPrice) PERSISTED,
    CreatedAt datetime2(0) NOT NULL CONSTRAINT DF_BookingService_CreatedAt DEFAULT SYSUTCDATETIME()
);
CREATE INDEX IX_BookingService_Booking ON hotel.BookingService(BookingID) INCLUDE (Amount, ServiceDate, ServiceID);
CREATE TABLE hotel.Payment (
    PaymentID bigint IDENTITY(1,1) NOT NULL CONSTRAINT PK_Payment PRIMARY KEY,
    BookingID bigint NOT NULL CONSTRAINT FK_Payment_Booking REFERENCES hotel.Booking(BookingID),
    EntryType varchar(7) NOT NULL CONSTRAINT CK_Payment_EntryType CHECK (EntryType IN ('CAPTURE','REFUND')),
    Amount decimal(14,2) NOT NULL CONSTRAINT CK_Payment_Amount CHECK (Amount > 0 AND Amount <= 100000000),
    Method varchar(10) NOT NULL CONSTRAINT CK_Payment_Method CHECK (Method IN ('CARD','CASH','TRANSFER')),
    Reference nvarchar(100) NOT NULL CONSTRAINT UQ_Payment_Reference UNIQUE,
    RecordedAt datetime2(0) NOT NULL CONSTRAINT DF_Payment_RecordedAt DEFAULT SYSUTCDATETIME(),
    CONSTRAINT CK_Payment_Reference CHECK (LEN(LTRIM(RTRIM(Reference))) > 0)
);
CREATE INDEX IX_Payment_Booking ON hotel.Payment(BookingID) INCLUDE (EntryType, Amount, RecordedAt);
CREATE TABLE hotel.RoomMaintenance (
    MaintenanceID bigint IDENTITY(1,1) NOT NULL CONSTRAINT PK_RoomMaintenance PRIMARY KEY,
    RoomID int NOT NULL CONSTRAINT FK_Maintenance_Room REFERENCES hotel.Room(RoomID),
    StartDate date NOT NULL,
    EndDate date NOT NULL,
    Reason nvarchar(200) NOT NULL,
    IsCancelled bit NOT NULL CONSTRAINT DF_Maintenance_IsCancelled DEFAULT 0,
    CreatedAt datetime2(0) NOT NULL CONSTRAINT DF_Maintenance_CreatedAt DEFAULT SYSUTCDATETIME(),
    CONSTRAINT CK_Maintenance_Dates CHECK (EndDate > StartDate AND StartDate >= '20200101' AND EndDate <= '20410101'),
    CONSTRAINT CK_Maintenance_Reason CHECK (LEN(LTRIM(RTRIM(Reason))) > 0)
);
CREATE INDEX IX_Maintenance_Room_Dates ON hotel.RoomMaintenance(RoomID, StartDate, EndDate) INCLUDE (IsCancelled);
CREATE TABLE hotel.CalendarDate (
    CalendarDate date NOT NULL CONSTRAINT PK_CalendarDate PRIMARY KEY,
    CalendarYear smallint NOT NULL,
    CalendarMonth tinyint NOT NULL,
    MonthStart date NOT NULL,
    IsoWeekday tinyint NOT NULL CONSTRAINT CK_Calendar_Weekday CHECK (IsoWeekday BETWEEN 1 AND 7)
);
WITH digits AS (
    SELECT n FROM (VALUES (0),(1),(2),(3),(4),(5),(6),(7),(8),(9)) AS v(n)
), numbers AS (
    SELECT a.n + 10*b.n + 100*c.n + 1000*d.n AS n
    FROM digits AS a CROSS JOIN digits AS b CROSS JOIN digits AS c CROSS JOIN digits AS d
), dates AS (
    SELECT DATEADD(day, n, CONVERT(date,'20200101')) AS d FROM numbers
    WHERE n < DATEDIFF(day, '20200101','20410101')
)
INSERT hotel.CalendarDate(CalendarDate, CalendarYear, CalendarMonth, MonthStart, IsoWeekday)
SELECT d, YEAR(d), MONTH(d), DATEFROMPARTS(YEAR(d), MONTH(d), 1),
    1 + DATEDIFF(day, '19000101', d) % 7 FROM dates;
GO
CREATE TRIGGER hotel.tr_Booking_StatusHistory ON hotel.Booking
AFTER INSERT, UPDATE
AS
BEGIN
    SET NOCOUNT ON;
    INSERT hotel.BookingStatusHistory(BookingID, OldStatus, NewStatus, ChangedBy)
    SELECT i.BookingID, d.Status, i.Status, ORIGINAL_LOGIN()
    FROM inserted AS i LEFT JOIN deleted AS d ON d.BookingID = i.BookingID
    WHERE d.BookingID IS NULL OR i.Status <> d.Status;
END;
GO
