-- ResourceGovernor_Uninstall.sql
-- Purpose: Safely remove Resource Governor configuration created by ResourceGovernor_Backup.sql
-- Author: Naga Diviseema
-- WARNING: Review before running. Requires sysadmin.

USE master;
GO

-- 1) Detach classifier function
ALTER RESOURCE GOVERNOR
WITH (CLASSIFIER_FUNCTION = NULL);
GO
ALTER RESOURCE GOVERNOR RECONFIGURE;
GO

-- 2) Drop classifier function (if exists)
IF OBJECT_ID('dbo.classifier_BackgroundJobs', 'FN') IS NOT NULL
BEGIN
    DROP FUNCTION dbo.classifier_BackgroundJobs;
END
GO

-- 3) Reset workload group settings and drop workload group
-- Ensure there are no active sessions in the group before dropping
IF EXISTS (SELECT 1 FROM sys.dm_resource_governor_workload_groups WHERE name = 'Group_Backup')
BEGIN
    -- You may want to MOVE sessions or wait until none are in the group
    DROP WORKLOAD GROUP Group_Backup;
END
GO

-- 4) Drop resource pool
IF EXISTS (SELECT 1 FROM sys.resource_governor_resource_pools WHERE name = 'Pool_Backup')
BEGIN
    DROP RESOURCE POOL Pool_Backup;
END
GO

ALTER RESOURCE GOVERNOR RECONFIGURE;
GO

-- 5) Optional: Drop the helper table
-- WARNING: Only drop if you no longer need it or have exported its contents
IF OBJECT_ID('dbo.RG_BackgroundJobs', 'U') IS NOT NULL
BEGIN
    DROP TABLE dbo.RG_BackgroundJobs;
END
GO
