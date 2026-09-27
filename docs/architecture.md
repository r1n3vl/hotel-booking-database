# Architecture and decisions

## Scope

This is a SQL-first operational database for a small hotel chain. A booking reserves one physical room for one date interval. A guest is the payer/contact; the model stores occupant counts but does not collect every occupant's identity. A reservation spanning multiple rooms is represented by separate bookings, without a group-reservation entity.

`hotel` owns storage and an internal lock helper. `api` exposes business operations. `report` exposes reusable read models. All schemas share the `dbo` owner so the procedures and views can use ownership chaining, while application users are denied direct writes.

## Relational design

Hotel, RoomType, Room, Guest, Service and Booking describe separate entities. BookingService resolves the booking-to-service relationship; one service can be posted multiple times on different dates. Payment is a ledger with multiple captures/refunds per booking. BookingStatusHistory records status events through a set-based trigger.

The operational model follows third-normal-form principles. Booking.NightlyRate and BookingService.UnitPrice intentionally store agreed-price snapshots. They represent historical facts, not caches of today's catalog prices. RoomAmount and service Amount are persisted computed columns, keeping arithmetic consistent.

Guest email is optional. A filtered unique index permits several guests without an email while preventing duplicate non-null emails. The API trims and lowercases supplied email addresses; its format check is intentionally basic, not email verification.

## Overlap and concurrency

Intervals are half-open. Two stays overlap when:

```sql
existing.CheckInDate < requested.CheckOutDate
AND existing.CheckOutDate > requested.CheckInDate
```

That condition alone is insufficient under concurrency: two sessions could both observe no reservation and then insert overlapping rows.

Every public operation that mutates a room's bookings, payments, services or maintenance acquires the same transaction-owned exclusive application lock: `hotel:room:<RoomID>`. Availability is checked only after the lock is acquired, inside the same transaction that inserts the reservation. Mutating procedures explicitly use READ COMMITTED for their work, reject outer/implicit transactions, enable XACT_ABORT and roll back in CATCH before rethrowing.

Different rooms can be processed concurrently. Operations on one room serialize even when their requested dates do not overlap. This deliberately favors a simple correctness argument over maximum throughput. Checked-out reservations keep blocking their historical scheduled intervals, preventing contradictory backdated stays.

The availability function is a read-only snapshot and never promises that a later booking will succeed. The create procedure always validates availability again.

Payment procedures also acquire a short global `hotel:payment-references` lock after the room lock. This gives references one consistent uniqueness/replay boundary even across bookings and across case-insensitive collations. It serializes payment writes across rooms, which is an explicit small-system trade-off. At higher volume, redesign the reference reservation mechanism and benchmark contention.

All application writes must use the API. A sysadmin or owner can bypass it and violate cross-row rules. The overlap invariant is not a table-level exclusion constraint; permissions and transaction protocols enforce it. Maintenance creation follows the same room lock as reservation creation.

## Booking lifecycle

Allowed transitions are CONFIRMED → CHECKED_IN → CHECKED_OUT and CONFIRMED → CANCELLED. Repeating the same status is a no-op and does not add another audit entry. A set-based trigger records initial creation and every actual status change, including multirow administrative updates.

The application supplies business dates. Check-in is not gated by the server's current clock, allowing imported/backdated demo operations. There are no actual arrival/departure timestamps, early checkout adjustments or time-zone calculations. UTC timestamps describe when records and status changes were written.

The room cannot be changed through the booking API. Confirmed bookings can be rescheduled at their original nightly rate, subject to availability and payment checks. Services are only allowed after check-in, so a rescheduled confirmed booking has no service lines under the API contract.

Room activity, capacity and catalog prices are managed administratively in this version. Administrators must preserve existing commitments. Current active room inventory is used as the reporting denominator; the system does not maintain historical room-inventory versions.

## Financial model

All amounts use fixed-precision decimal values in PLN. No floating-point money is used. There are no exchange rates, taxes, discount rules, invoices, cancellation fees or external payment integrations.

For an active booking:

`TotalAmount = nights × agreed nightly rate + sum(service quantities × agreed unit prices)`

`NetPaid = captures − refunds`

`BalanceDue = TotalAmount − NetPaid`

Cancellation sets the effective bill to zero. A negative balance then means a refund is due. Refunds are separate positive-valued ledger entries; original captures remain unchanged. Captures cannot overpay the bill, and refunds cannot make net paid negative. Checked-out stays must remain settled; post-checkout refunds/credit notes are outside the model.

Payment Reference is an idempotency key. Replaying identical booking/type/amount/method parameters returns the original PaymentID, even if the booking status subsequently changed. Reusing the reference with different parameters raises 51010. This is database-level recording idempotency, not evidence of a payment provider transaction.

Booking services have no idempotency key or correction API. A service request should be submitted once; service voids and retry-safe charge requests are potential extensions.

Services and payments are aggregated separately before joining to bookings. Joining both child tables first would multiply amounts for bookings with several services and several payments. The integration suite includes that case.

## Reporting definitions

| Metric | Definition |
| --- | --- |
| Booked room night | One non-cancelled scheduled room for one calendar date; checkout is excluded |
| Booked room revenue | Agreed nightly rate allocated to each booked night |
| Sellable rooms | Currently active rooms minus active maintenance on that date |
| Booked occupancy | Booked room nights / sellable room nights × 100 |
| Booked ADR | Booked room revenue / booked room nights |
| Booked RevPAR | Booked room revenue / sellable room nights |
| Net cash collected | Captures minus refunds by payment-recording date |
| Guest booked value | Effective room and service charges across the guest's bookings |
| Cancellation rate | Cancelled bookings / all bookings, grouped by scheduled arrival month |

These are scheduled-booking metrics, not audited recognized revenue or measured physical occupancy. Monthly ratios divide monthly sums, rather than averaging daily percentages. A stay crossing a month boundary is split by CalendarDate. Zero denominators return NULL; zero revenue with positive capacity yields zero RevPAR.

Views represent current booking status. A later cancellation changes historical booked metrics. There is no as-of status reconstruction or slowly changing inventory dimension. Room/service reports are suitable for portfolio analytics with those definitions, not financial reporting certification.

## Indexes and performance

The overlap-query index starts with RoomID and CheckInDate, with CheckOutDate and status available to evaluate the remaining interval condition. This does not make both interval boundaries independently seekable. Guest-booking, service-booking, payment-booking and maintenance indexes support their corresponding reads and aggregates.

Use `examples/03_query_plan.sql` with **Include Actual Execution Plan** in SSMS to inspect plans and logical reads. The small seed dataset may legitimately favor a scan. No invented benchmark or unsupported performance improvement is claimed.

## Extensions

Possible next steps: group reservations, nightly rate plans, durable idempotency keys for booking/service requests, actual check-in/out events, service reversals, staff identity, tenant-specific permissions, a tested migration path, backup/restore exercises and a separate analytics warehouse. This repository implements an OLTP database with reporting views, not a star-schema warehouse.
