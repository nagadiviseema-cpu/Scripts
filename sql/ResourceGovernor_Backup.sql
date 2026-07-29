-- ResourceGovernor_Backup.sql
-- Purpose: Configure SQL Server Resource Governor to cap backup jobs and route SQL Agent backup job sessions
-- Author: Converted from provided instructions
-- Notes: Update the job name filter in the INSERT/select section to match your environment.

USE master;
GO

-- Step 1: Capture Backup Jobs into a helper table
IF OBJECT_ID('dbo.RG_BackgroundJobs', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.RG_BackgroundJobs
    (
        job_id UNIQUEIDENTIFIER,
        name SYSNAME,
        match_string NVARCHAR(256) PRIMARY KEY
    );
END
GO

-- Populate the table with SQL Agent jobs whose name matches your backup job naming convention
-- Adjust the LIKE pattern below as needed
INSERT INTO dbo.RG_BackgroundJobs (job_id, name, match_string)
SELECT
    job_id,
    name,
    'SQLAgent - TSQL JobStep (Job 0x'
    + CONVERT(VARCHAR(34), CONVERT(VARBINARY(16), job_id), 1)
    + '%'
FROM msdb.dbo.sysjobs
WHERE UPPER(name) LIKE '%BACKUP APP%'; -- Filter your required jobs here
GO

-- Step 2: Create Resource Pool and Workload Group
-- Adjust MIN_CPU_PERCENT, MAX_CPU_PERCENT, CAP_CPU_PERCENT to your requirements
IF NOT EXISTS (SELECT 1 FROM sys.resource_governor_resource_pools WHERE name = 'Pool_Backup')
BEGIN
    CREATE RESOURCE POOL Pool_Backup
    WITH
    (
        MIN_CPU_PERCENT = 20, -- Guaranteed minimum CPU
        MAX_CPU_PERCENT = 50, -- Soft cap when contention exists
        CAP_CPU_PERCENT = 60  -- Hard cap
    );
END
GO

IF NOT EXISTS (SELECT 1 FROM sys.dm_resource_governor_workload_groups WHERE name = 'Group_Backup')
BEGIN
    CREATE WORKLOAD GROUP Group_Backup
    USING Pool_Backup;
END
GO

ALTER RESOURCE GOVERNOR RECONFIGURE;
GO

-- Limit parallelism and memory grants for the backup workload group
ALTER WORKLOAD GROUP Group_Backup
WITH
(
    MAX_DOP = 2,
    REQUEST_MAX_MEMORY_GRANT_PERCENT = 25
);
GO

ALTER RESOURCE GOVERNOR RECONFIGURE;
GO

-- Step 3: Create classifier function to map sessions to the backup workload group
CREATE OR ALTER FUNCTION dbo.classifier_BackgroundJobs()
RETURNS sysname
WITH SCHEMABINDING
AS
BEGIN
    DECLARE 
        @app NVARCHAR(256) = APP_NAME(),
        @group SYSNAME = N'default';

    -- Only classify SQL Agent jobs
    IF @app LIKE N'%TSQL JobStep%'
    BEGIN
        IF EXISTS
        (
            SELECT 1
            FROM dbo.RG_BackgroundJobs
            WHERE @app LIKE match_string
        )
        BEGIN
            SET @group = N'Group_Backup';
        END
    END

    RETURN (@group);
END
GO

-- Step 4: Attach classifier function to Resource Governor
USE master;
GO
ALTER RESOURCE GOVERNOR
WITH (CLASSIFIER_FUNCTION = dbo.classifier_BackgroundJobs);
GO
ALTER RESOURCE GOVERNOR RECONFIGURE;
GO

-- Step 5: Validation - run this to see sessions and their assigned workload group and pool
SELECT
    s.session_id,
    s.login_name,
    s.program_name,
    g.name AS workload_group,
    p.name AS resource_pool
FROM sys.dm_exec_sessions s
JOIN sys.dm_resource_governor_workload_groups g
    ON s.group_id = g.group_id
JOIN sys.dm_resource_governor_resource_pools p
    ON g.pool_id = p.pool_id
WHERE s.is_user_process = 1
ORDER BY s.session_id;
GO

-- Cleanup notes (optional): If you need to remove changes, drop the classifier or workload group/resource pool after verification.
