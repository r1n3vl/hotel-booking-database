# T-SQL API reference

Use named arguments in application code. Parameters are scalar SQL Server values. All output IDs are optional OUTPUT parameters. Procedures do not emit result sets; read through the reporting views or explicitly select an output variable. Do not wrap API calls in a transaction and keep implicit transactions disabled.

| Procedure | Required arguments | Optional/default arguments | Output |
| --- | --- | --- | --- |
| api.usp_CreateGuest | @FirstName, @LastName | @Email=NULL, @Phone=NULL | @GuestID int |
| api.usp_CreateBooking | @GuestID, @RoomID, @CheckInDate, @CheckOutDate | @Adults=1, @Children=0 | @BookingID bigint |
| api.usp_RescheduleBooking | @BookingID, @CheckInDate, @CheckOutDate | — | — |
| api.usp_ChangeBookingStatus | @BookingID, @NewStatus | — | — |
| api.usp_AddService | @BookingID, @ServiceID, @ServiceDate | @Quantity=1 | @BookingServiceID bigint |
| api.usp_RecordPayment | @BookingID, @EntryType, @Amount, @Method, @Reference | — | @PaymentID bigint |
| api.usp_AddMaintenance | @RoomID, @StartDate, @EndDate, @Reason | — | @MaintenanceID bigint |
| api.usp_CancelMaintenance | @MaintenanceID | — | — |

`hotel.usp_LockRoom` is an internal helper, not an application endpoint.

## Create and inspect a reservation

```sql
DECLARE @BookingID bigint;
EXEC api.usp_CreateBooking
    @GuestID = 1,
    @RoomID = 1,
    @CheckInDate = '20300510',
    @CheckOutDate = '20300513',
    @Adults = 1,
    @Children = 0,
    @BookingID = @BookingID OUTPUT;

SELECT * FROM report.vBookingFinancials WHERE BookingID = @BookingID;
```

Use real IDs discovered from your database. A SELECT showing availability does not reserve a room; only a successful CreateBooking call commits a reservation.

## Payment retry

```sql
DECLARE @PaymentID bigint;
EXEC api.usp_RecordPayment
    @BookingID = 1,
    @EntryType = 'CAPTURE',
    @Amount = 100.00,
    @Method = 'CARD',
    @Reference = N'client-generated-unique-reference',
    @PaymentID = @PaymentID OUTPUT;
SELECT @PaymentID AS PaymentID;
```

The booking must exist, accept payment and have enough balance. Repeating the same request returns the same PaymentID. Reuse after changing the amount, booking, entry type or method fails. Output IDs should be used only after successful completion.

## Error contract

| Number | Meaning |
| --- | --- |
| 51000 | Caller has an outer transaction or implicit transactions enabled |
| 51001 | Invalid dates, quantity or payment parameters |
| 51002 | Requested guest, room, booking, active service or maintenance record does not exist |
| 51003 | Room is inactive |
| 51004 | Invalid occupant count or capacity exceeded |
| 51005 | Booking/maintenance interval conflict |
| 51006 | Invalid state transition or operation unavailable in the current status |
| 51007 | Outstanding balance prevents check-out |
| 51008 | Financial rule violation: overpayment, overrefund, insufficient refund before shortening, or settled refund restriction |
| 51009 | Application lock acquisition failed; retry the whole operation with bounded backoff |
| 51010 | Existing payment reference has different parameters |
| 51020 | Demonstration seed requires an empty application database |
| 51030 | Lifecycle example could not find a suitable room |

Native errors can also occur: missing required values (515), FK/check violations (547), duplicate unique values (2601/2627), permission denied (229), deadlock (1205), connection or conversion errors. The API does not translate every native SQL Server failure into a custom number. Type conversion/truncation follows SQL Server parameter rules; clients should validate types and length before calling.

No booking/service request idempotency token is implemented. After an ambiguous connection failure, reconcile the operation before blindly retrying a creation. Payment recording has the explicit replay guarantee described above.
