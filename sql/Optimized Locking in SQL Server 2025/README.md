# Optimized Locking in SQL Server 2025

Scripts and notes for implementing and testing optimized locking in SQL Server 2025.
# Optimized Locking in SQL Server 2025

## Preparing a SQL Server 2025 Demo

The following example should be executed only in a development or test environment.

Create a database:

```sql
USE master;
GO

CREATE DATABASE OptimizedLockingLab;
GO
```

Optimized locking requires **Accelerated Database Recovery (ADR)**.

Enable ADR:

```sql
ALTER DATABASE OptimizedLockingLab
SET ACCELERATED_DATABASE_RECOVERY = ON;
GO
```

Enable RCSI so that LAQ can provide its full concurrency benefits:

```sql
ALTER DATABASE OptimizedLockingLab
SET READ_COMMITTED_SNAPSHOT ON
WITH ROLLBACK IMMEDIATE;
GO
```

Finally, enable optimized locking:

```sql
ALTER DATABASE OptimizedLockingLab
SET OPTIMIZED_LOCKING = ON;
GO
```

In SQL Server 2025, optimized locking is configured at the database level.

---

## Verifying Optimized Locking

Before testing, verify the database configuration:

```sql
SELECT
    name,
    is_accelerated_database_recovery_on,
    is_read_committed_snapshot_on,
    is_optimized_locking_on
FROM sys.databases
WHERE name = N'OptimizedLockingLab';
GO
```

You can also check optimized locking directly:

```sql
USE OptimizedLockingLab;
GO

SELECT DATABASEPROPERTYEX
(
    DB_NAME(),
    'IsOptimizedLockingOn'
) AS IsOptimizedLockingEnabled;
GO
```

A value of `1` indicates that optimized locking is enabled.

---

## Example 1: Observing TID Locking

Create a simple table:

```sql
USE OptimizedLockingLab;
GO

CREATE TABLE dbo.AccountBalance
(
    AccountID int NOT NULL
        CONSTRAINT PK_AccountBalance PRIMARY KEY,
    Balance decimal(12,2) NOT NULL
);
GO

INSERT dbo.AccountBalance
(
    AccountID,
    Balance
)
VALUES
    (1, 1000.00),
    (2, 2000.00),
    (3, 3000.00),
    (4, 4000.00),
    (5, 5000.00);
GO
```

Start a transaction:

```sql
BEGIN TRANSACTION;

UPDATE dbo.AccountBalance
SET Balance = Balance + 100;
```

Do not commit yet.

Inspect the locks owned by the current session:

```sql
SELECT
    request_session_id,
    resource_type,
    request_mode,
    request_status,
    resource_description
FROM sys.dm_tran_locks
WHERE request_session_id = @@SPID
ORDER BY resource_type;
GO
```

With optimized locking active, an important resource to look for is:

```text
XACT
```

The transaction can retain an exclusive lock on the transaction resource rather than retaining an exclusive key lock for every modified row for the entire transaction.

Finish the test:

```sql
ROLLBACK TRANSACTION;
GO
```

For a more meaningful demonstration, repeat the experiment with thousands of rows and compare the lock inventory with optimized locking enabled and disabled.

---

## Example 2: LAQ and Concurrent Updates

The difference becomes especially interesting when two transactions update different rows.

Create a small heap:

```sql
CREATE TABLE dbo.PaymentQueue
(
    PaymentID int NOT NULL,
    Amount int NOT NULL
);
GO

INSERT dbo.PaymentQueue
(
    PaymentID,
    Amount
)
VALUES
    (1, 100),
    (2, 200),
    (3, 300);
GO
```

Open two SSMS query windows.

### Session 1

Execute:

```sql
BEGIN TRANSACTION;

UPDATE dbo.PaymentQueue
SET Amount = Amount + 50
WHERE PaymentID = 1;

-- Do not commit yet
```

Session 1 now has an uncommitted modification.

In another window execute:

### Session 2

```sql
BEGIN TRANSACTION;

UPDATE dbo.PaymentQueue
SET Amount = Amount + 50
WHERE PaymentID = 2;

COMMIT TRANSACTION;
```

Notice something important.

Session 2 wants:

```text
PaymentID = 2
```

Session 1 modified:

```text
PaymentID = 1
```

These transactions do not logically conflict.

With LAQ available under `READ COMMITTED` and RCSI, SQL Server can evaluate committed row versions while searching for the row that satisfies Session 2's predicate. It does not have to acquire an update lock on every examined row before determining whether the row qualifies.

That allows SQL Server to avoid some unnecessary blocking between independent writers.

Finish Session 1:

```sql
ROLLBACK TRANSACTION;
```

---

## Example 3: Optimized Locking Does Not Eliminate Real Blocking

A common misunderstanding is that optimized locking eliminates blocking.

It does not.

Run this in Session 1:

```sql
BEGIN TRANSACTION;

UPDATE dbo.PaymentQueue
SET Amount = Amount + 50
WHERE PaymentID = 1;

-- Leave transaction open
```

Now Session 2 attempts:

```sql
BEGIN TRANSACTION;

UPDATE dbo.PaymentQueue
SET Amount = Amount + 25
WHERE PaymentID = 1;

COMMIT TRANSACTION;
```

Both sessions want to modify the same row.

Session 2 must wait.

That behavior is correct.

Allowing Session 2 to overwrite an uncommitted modification from Session 1 would violate SQL Server's transaction consistency guarantees.

Optimized locking therefore distinguishes between two situations:

```text
Different rows
-------------------------
Transaction A -> Row 1
Transaction B -> Row 2

Potentially greater concurrency


Same row
-------------------------
Transaction A -> Row 1
Transaction B -> Row 1

Real conflict -> Blocking
```

Optimized locking reduces **unnecessary contention**. It does not remove **necessary serialization**.

---

## Monitoring Blocking with Optimized Locking

Existing SQL Server monitoring solutions frequently focus on resources such as:

```text
KEY
PAGE
OBJECT
```

With optimized locking, transaction resources become increasingly important.

While Session 2 is blocked, examine requests:

```sql
SELECT
    session_id,
    status,
    command,
    wait_type,
    wait_time,
    blocking_session_id,
    wait_resource
FROM sys.dm_exec_requests
WHERE blocking_session_id <> 0;
GO
```

Then inspect locks:

```sql
SELECT
    request_session_id,
    resource_type,
    request_mode,
    request_status,
    resource_description
FROM sys.dm_tran_locks
ORDER BY request_session_id,
         resource_type;
GO
```

SQL Server 2025 introduces transaction-related lock waits that administrators may encounter when optimized locking is involved.

Examples include:

```text
LCK_M_S_XACT
LCK_M_S_XACT_READ
LCK_M_S_XACT_MODIFY
```

This means monitoring systems written with the assumption that blocking always involves `KEY`, `PAGE`, or `OBJECT` resources may need to be updated.

---

## Lock Memory Reduction

One of the most valuable benefits of optimized locking appears during large transactions.

Imagine:

```sql
BEGIN TRANSACTION;

UPDATE dbo.LargeOrderTable
SET ProcessingStatus = 'Ready'
WHERE BatchID = 500;

-- 50,000 rows affected

COMMIT TRANSACTION;
```

Traditional locking might require SQL Server to retain a large collection of locks during the transaction.

Conceptually:

```text
50,000 modified rows
       |
Thousands of retained locks
       |
Higher lock memory
       |
Possible escalation
```

Optimized locking changes the long-duration lock footprint:

```text
50,000 modified rows
       |
Short-duration modification locks
       |
Transaction protected using TID
       |
Far fewer locks retained
       |
Lower lock memory pressure
```

The exact number of locks observed should not be treated as a fixed guarantee. Execution plans, indexes, SQL Server builds, query shape, and other engine decisions influence the lock inventory.

The important point is the architectural change: SQL Server no longer needs to retain every modification lock until transaction completion in the traditional manner.

---

## What About Lock Escalation?

SQL Server can escalate many fine-grained locks into a larger lock when maintaining the individual locks becomes expensive.

For example:

```text
Thousands of KEY locks
          |
          V
     Escalation
          |
          V
      TABLE lock
```

A table lock can dramatically reduce concurrency because other transactions that need the same table may now be blocked.

Because optimized locking can greatly reduce the number of locks retained by a transaction, lock escalation becomes substantially less likely for workloads that benefit from the feature.

That can be particularly valuable for:

- Order-processing systems
- Payment processing
- Inventory applications
- Payroll systems
- Message/work queues
- Batch-processing applications
- High-volume OLTP systems

---

## Optimized Locking and RCSI Are Related but Different

It is important not to treat optimized locking and RCSI as the same feature.

RCSI primarily improves **reader/writer concurrency**.

Instead of a reader waiting for a writer's exclusive lock, SQL Server can provide the reader with an appropriate committed row version.

Conceptually:

```sql
Writer
  |
Updates Row A
  |
Reader
  |
Reads committed row version
```

LAQ extends row-versioning concepts to the process by which writers identify rows that should be modified.

Therefore:

```text
Optimized Locking
      |
      +---- TID Locking
      |
      +---- LAQ
               |
               +---- Requires RCSI
```

TID locking can provide benefits without RCSI.

LAQ requires RCSI.

For maximum benefit, Microsoft recommends RCSI together with the default `READ COMMITTED` isolation level.

---

## Locking Hints Can Reduce the Benefit

Applications sometimes contain hints such as:

```text
UPDLOCK
```

```text
HOLDLOCK
```

```text
XLOCK
```

or:

```sql
READCOMMITTEDLOCK
```

For example:

```sql
SELECT *
FROM dbo.PaymentQueue WITH (UPDLOCK)
WHERE PaymentID = 1;
```

SQL Server continues to honor explicit locking semantics when optimized locking is enabled.

Consequently, applications containing large numbers of locking hints may not receive the same concurrency improvement as applications relying on SQL Server's normal locking decisions.

This does not mean that all locking hints should automatically be removed.

Some applications intentionally use `UPDLOCK`, `HOLDLOCK`, or stronger isolation semantics to implement a particular concurrency design.

Instead, existing hints should be reviewed to determine whether they are still necessary.

---

## What Optimized Locking Does Not Fix

Optimized locking should not be viewed as a universal solution for database blocking.

It does not fix every concurrency problem.

#### 1. Two transactions updating the same row

```sql
UPDATE dbo.AccountBalance
SET Balance = Balance - 100
WHERE AccountID = 1;
```

If another active transaction is already modifying `AccountID = 1`, waiting is still necessary.

#### 2. Long-running transactions

An application that performs:

```sql
BEGIN TRANSACTION

Update database

Call external API

Wait 15 seconds

Generate document

Send message

COMMIT
```

still has a transaction-design problem.

Optimized locking does not make unnecessarily long transactions a good design.

#### 3. Schema locks

Optimized locking primarily changes locking behavior associated with DML operations.

It does not eliminate schema and metadata synchronization.

Operations such as:

```sql
ALTER TABLE
```

can still require schema modification locks.

#### 4. Poor indexing

Consider:

```sql
UPDATE dbo.Orders
SET Status = 'Complete'
WHERE CustomerReference = 'ABC123';
```

If `CustomerReference` is not properly indexed, SQL Server may still need to examine a large amount of data.

Optimized locking does not replace indexing and execution-plan optimization.

#### 5. Poor application concurrency design

Optimized locking cannot automatically correct application logic that depends on accidental blocking for business ordering.

Applications requiring a guaranteed order should implement that requirement explicitly.

---

## SQL Server 2025 Availability

Optimized locking is available in **SQL Server 2025 (17.x)**.

For SQL Server 2025, it is **not enabled by default**. It can be enabled at the individual database level once Accelerated Database Recovery is enabled.

It is also available in Microsoft's cloud SQL platforms, including Azure SQL Database and supported Azure SQL Managed Instance configurations.

This distinction matters during migrations.

Upgrading an application to SQL Server 2025 does not necessarily mean every database immediately begins using optimized locking.

Database configuration must be verified.

---

## Production Deployment Considerations

Enabling optimized locking should be treated as a database-engine configuration change rather than simply another performance switch.

Before enabling it in a production environment, establish a workload baseline.

Useful measurements include:

```text
Transactions/sec
Batch Requests/sec
Lock waits
Lock escalations
Deadlocks
Average transaction duration
Long-running transactions
CPU utilization
Query duration
Version-store usage
tempdb activity
```

After enabling optimized locking, compare the same measurements.

Pay particular attention to applications that:

- Use explicit locking hints.
- Depend on specific blocking behavior.
- Use long transactions.
- Perform large batch updates.
- Have heavy writer/writer contention.
- Use custom deadlock-monitoring software.
- Parse lock resources from DMVs or Extended Events.
- Depend heavily on `READ COMMITTED` semantics.

A phased rollout is preferable:

```text
Development
     |
     V
Performance Testing
     |
     V
Concurrency Testing
     |
     V
Staging
     |
     V
Limited Production
     |
     V
Full Production
```

---

## Practical Example: Order Processing

Consider an e-commerce system processing thousands of orders concurrently.

Worker A executes:

```sql
UPDATE dbo.Orders
SET Status = 'Processing'
WHERE OrderID = 50001;
```

Worker B executes:

```sql
UPDATE dbo.Orders
SET Status = 'Processing'
WHERE OrderID = 50002;
```

Worker C executes:

```sql
UPDATE dbo.Orders
SET Status = 'Processing'
WHERE OrderID = 50003;
```

These transactions are logically independent.

A highly concurrent system should allow them to progress independently whenever possible.

Optimized locking helps SQL Server move closer to that goal by reducing the number and duration of locks involved in finding and modifying qualifying rows.

However, if Worker D executes:

```sql
UPDATE dbo.Orders
SET Status = 'Cancelled'
WHERE OrderID = 50001;
```

while Worker A's modification to order `50001` remains uncommitted, Worker D still needs to wait.

That is not a performance defect.

That is correct transactional behavior.

---

## Traditional vs. Optimized Locking

| Area | Traditional Locking | Optimized Locking |
| --- | --- | --- |
| Modified-row locks                       | Can remain until transaction completion       | Can be released much sooner               |
| Transaction protection                   | Primarily retained row/key/page locks         | TID/XACT infrastructure                   |
| Lock memory                              | Can become significant for large transactions | Usually substantially reduced             |
| Lock escalation                          | More likely with large lock counts            | Much less likely for benefiting workloads |
| Predicate evaluation                     | Locks may be acquired before qualification    | LAQ can qualify before locking            |
| Independent writers                      | Can experience unnecessary blocking           | Greater opportunity for concurrency       |
| Same-row conflict                        | Blocks                                        | Still blocks                              |
| Schema locking                           | Exists                                        | Still exists                              |
| Explicit locking hints                   | Honored                                       | Still honored and may reduce benefits     |
| RCSI requirement                         | Not inherently required                       | Required specifically for LAQ             |

---

## Recommended Configuration

A typical SQL Server 2025 database configuration for evaluating the complete optimized-locking experience is:

```sql
ALTER DATABASE YourDatabase
SET ACCELERATED_DATABASE_RECOVERY = ON;
GO

ALTER DATABASE YourDatabase
SET READ_COMMITTED_SNAPSHOT ON
WITH ROLLBACK IMMEDIATE;
GO

ALTER DATABASE YourDatabase
SET OPTIMIZED_LOCKING = ON;
GO
```

Then verify:

```sql
SELECT
    name,
    is_accelerated_database_recovery_on AS ADR,
    is_read_committed_snapshot_on       AS RCSI,
    is_optimized_locking_on             AS OptimizedLocking
FROM sys.databases
WHERE name = N'YourDatabase';
GO
```

`WITH ROLLBACK IMMEDIATE` can terminate active sessions when changing the RCSI setting, so this example should **not** be copied directly into a production deployment without an appropriate maintenance and rollout plan.

---

## Final Thoughts

Optimized locking represents an important evolution of SQL Server's concurrency architecture.

The feature does not attempt to remove locks. Locks remain essential for maintaining ACID transaction semantics.

Instead, SQL Server 2025 reduces the cost of locking by changing two important behaviors.

**Transaction ID locking** allows SQL Server to protect a transaction without retaining potentially thousands of row and page locks until commit.

**Lock After Qualification** allows SQL Server, when RCSI is enabled, to determine whether a row qualifies for modification using its latest committed version before acquiring the modification lock.

Together, these mechanisms can produce:

```text
Fewer retained locks
        +
Lower lock memory
        +
Less unnecessary blocking
        +
Less lock escalation
        +
Better concurrency
```

The most important takeaway is therefore not that SQL Server 2025 eliminates locking.

It is that SQL Server can now maintain the same fundamental transaction guarantees while retaining substantially fewer locks and avoiding some locking that was previously necessary during row qualification.

For high-concurrency OLTP applications, that architectural change can translate into greater throughput and more predictable behavior—but it should still be combined with sound indexing, short transactions, appropriate isolation levels, careful concurrency design, and production monitoring.
