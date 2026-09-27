# Data dictionary

All tables are in the `hotel` schema. `int`/`bigint` identities are surrogate primary keys unless stated otherwise. Strings use Unicode where user-entered names or descriptions are expected. UTC event timestamps use `datetime2(0)`; stay and service dates use `date`. Every amount is PLN.

| Table | Grain / purpose | Primary key | References and notable columns |
| --- | --- | --- | --- |
| Hotel | One hotel property | HotelID | Unique Code; Name, City, Address |
| RoomType | One shared room category | RoomTypeID | Unique Name; Capacity 1–8 |
| Room | One physical room | RoomID | HotelID → Hotel; RoomTypeID → RoomType; hotel/room number unique; NightlyRate; IsActive |
| Guest | One paying guest/contact | GuestID | FirstName, LastName, optional Email/Phone; filtered unique Email; CreatedAt |
| Booking | One room reservation | BookingID | GuestID → Guest; RoomID → Room; CheckInDate, CheckOutDate, Adults, Children, NightlyRate, Status, RoomAmount, VersionStamp |
| BookingStatusHistory | One creation/status-change event | HistoryID | BookingID → Booking; OldStatus, NewStatus, ChangedAt, ChangedBy |
| Service | One service catalog item | ServiceID | Unique Name; UnitPrice; IsActive |
| BookingService | One service charge line | BookingServiceID | BookingID → Booking; ServiceID → Service; ServiceDate, Quantity, UnitPrice, computed Amount |
| Payment | One capture or refund record | PaymentID | BookingID → Booking; EntryType, Amount, Method, globally unique Reference, RecordedAt |
| RoomMaintenance | One unavailable room interval | MaintenanceID | RoomID → Room; StartDate, EndDate, Reason, IsCancelled |
| CalendarDate | One date from 2020-01-01 through 2040-12-31 | CalendarDate | CalendarYear, CalendarMonth, MonthStart, IsoWeekday (Monday=1) |
| SchemaVersion | One installed baseline marker | VersionNumber | AppliedAt, Description; current baseline=1 |

## Booking fields

| Field | Type | Rule |
| --- | --- | --- |
| BookingID | bigint identity | Stable reservation identity; identity gaps are normal |
| GuestID / RoomID | int | Mandatory foreign keys |
| CheckInDate / CheckOutDate | date | 1–365 nights; within reporting calendar; checkout excluded |
| Adults / Children | tinyint | At least one adult; total ≤8 and API validates room capacity |
| NightlyRate | decimal(12,2) | Snapshot >0 and ≤100,000 PLN |
| Status | varchar(12) | CONFIRMED, CHECKED_IN, CHECKED_OUT or CANCELLED |
| RoomAmount | decimal(14,2), computed persisted | Date difference × snapshot rate |
| CreatedAt / UpdatedAt | datetime2(0) | UTC; status and reschedule operations update UpdatedAt |
| VersionStamp | rowversion | SQL Server change token; exposed for future optimistic concurrency, not used by this API |

The database checks local row validity and referential integrity. Procedures enforce cross-row overlap, current capacity, transition, balance and service-date rules. There are no cascading deletes; financial and audit records should not disappear when deleting a parent.

## Payment semantics

CAPTURE and REFUND both store positive Amount. Signed movement is calculated in reporting. Methods are CARD, CASH and TRANSFER. Reference must be nonblank and is unique according to the database collation; the API trims it and compares retries using that same collation. Applications should use opaque consistent reference values.

## Published read objects

| Object | Grain |
| --- | --- |
| report.vBookingFinancials | One row per booking, with effective charges, captures, refunds, net paid and balance |
| report.vRoomNightLedger | One row per non-cancelled booking and occupied scheduled night |
| report.vDailyHotelPerformance | One row per hotel/calendar date, including zero-booking dates |
| report.vGuestSummary | One row per guest, including guests with no bookings |
| report.vPaymentLedger | One row per payment with signed amount and running booking balance |
| report.fn_AvailableRooms | One row per currently available eligible room for the supplied stay |

Extending the calendar beyond 2040 also requires updating the corresponding booking/maintenance date checks and procedure/function guards.
