## Prerequisites

`OPTIMIZED_SP_EXECUTESQL` is a **database-scoped configuration** introduced in SQL Server 2025.

Before enabling it, verify that:

* You are running SQL Server 2025 or later.
* The workload uses `sp_executesql` for parameterized dynamic SQL.
* You have appropriate permissions to change database-scoped configurations.
* The workload has sufficient concurrency for compilation contention to be relevant.
* You have baseline performance metrics available for comparison.

> **Note:** `OPTIMIZED_SP_EXECUTESQL` is designed specifically for statements executed through `sp_executesql`. It does not change the compilation behavior of all SQL statements across the database.

## Enabling `OPTIMIZED_SP_EXECUTESQL`

Enable the configuration with `ALTER DATABASE SCOPED CONFIGURATION`:

```sql
ALTER DATABASE SCOPED CONFIGURATION
SET OPTIMIZED_SP_EXECUTESQL = ON;
```

The setting applies to the current database.

### Verify the Configuration

You can verify the current setting with:

```sql
SELECT
    name,
    value,
    value_for_secondary
FROM sys.database_scoped_configurations
WHERE name = 'OPTIMIZED_SP_EXECUTESQL';
```

A value of `1` indicates that the configuration is enabled.

### Disable the Configuration

If you need to turn it off:

```sql
ALTER DATABASE SCOPED CONFIGURATION
SET OPTIMIZED_SP_EXECUTESQL = OFF;
```

## Recommended Deployment Approach

For production systems, enable the configuration in a controlled manner:

```text
Baseline Performance
        │
        ▼
Test in Non-Production
        │
        ▼
Enable OPTIMIZED_SP_EXECUTESQL
        │
        ▼
Monitor Query Store / DMVs
        │
        ▼
Compare Against Baseline
        │
        ▼
Production Deployment
```

Before and after enabling the configuration, monitor metrics such as:

* CPU utilization
* Query compilation activity
* Query duration
* Query throughput
* Wait statistics
* Query Store runtime statistics
* Plan-cache behavior


Its primary purpose is coordinating concurrent compilation of identical sp_executesql batches, thereby avoiding redundant compilation work. 
Plan reuse is a consequence of that coordination, not the main feature itself.
